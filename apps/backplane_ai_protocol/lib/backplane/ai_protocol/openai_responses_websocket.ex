defmodule Backplane.AiProtocol.OpenAIResponsesWebSocket do
  @moduledoc """
  Pure native Responses WebSocket message codec for client applications.

  Encoders return one UTF-8 JSON text message, not an SSE record or a WebSocket
  frame. `decode_event/2` accepts one complete reassembled text message and
  preserves all native fields, including unknown event types and correlation IDs.
  It does not apply the unrelated `Backplane.AiProtocol.Wire` envelope.

  The host owns sockets, authentication, handshake validation, fragmentation,
  correlation, deadlines, backpressure and cleanup. This module neither submits
  nor retries requests and never interprets a disconnect as cancellation.
  No interrupt, cancel or steering operation is implied by this codec.

  Both directions accept `:max_encoded_bytes` (default 2 MiB) and the existing
  `:limits` structural profile. Bounds apply to complete messages; the transport
  must enforce its own frame and buffering bounds before reassembly.
  """

  alias Backplane.AiProtocol.{Codec, Error, Request, Serialization, Validation}

  @default_max_encoded_bytes 2_097_152

  @doc "Encodes native string-keyed create parameters, preserving provider extensions."
  @spec encode_create(map(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_create(params, opts \\ [])

  def encode_create(params, opts) when is_map(params) and not is_struct(params) do
    with :ok <- validate_options(opts),
         :ok <- Validation.term(params, Keyword.get(opts, :limits, %{})),
         :ok <- string_keys(params),
         :ok <- create_parameters(params),
         {:ok, json} <- Serialization.to_json(Map.put(params, "type", "response.create")),
         {:ok, _event} <- decode_event(json, opts) do
      {:ok, json}
    end
  end

  def encode_create(_params, _opts),
    do: invalid("Responses create parameters must be a native map")

  @doc "Encodes a canonical request through the existing Responses codec without HTTP stream flags."
  @spec encode_request(Request.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_request(request, opts \\ []) do
    with :ok <- validate_options(opts),
         {:ok, params} <- Codec.encode_request(:openai_responses, request, opts) do
      params |> Map.delete("stream") |> encode_create(opts)
    end
  end

  @doc "Decodes one complete native text message; unknown events and fields remain intact."
  @spec decode_event(binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def decode_event(message, opts \\ []) do
    with :ok <- validate_options(opts) do
      Serialization.decode_and_validate(message, &event/1, opts)
    end
  end

  defp event(%{"type" => type} = event) when is_binary(type) and byte_size(type) > 0,
    do: {:ok, event}

  defp event(_), do: invalid("Responses event requires a nonempty string type")

  defp create_parameters(params) do
    cond do
      Map.has_key?(params, "stream") or Map.has_key?(params, "background") ->
        invalid("Responses WebSocket does not accept HTTP stream or background fields")

      Map.has_key?(params, "type") and params["type"] != "response.create" ->
        invalid("Expected response.create parameters")

      not is_binary(params["model"]) or params["model"] == "" ->
        invalid("Responses create requires a nonempty model string")

      true ->
        :ok
    end
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      max = Keyword.get(opts, :max_encoded_bytes, @default_max_encoded_bytes)
      limits = Keyword.get(opts, :limits, %{})
      defaults = Validation.default_limits()

      if is_integer(max) and max > 0 and is_map(limits) and
           Enum.all?(limits, fn {key, value} ->
             Map.has_key?(defaults, key) and is_integer(value) and value > 0
           end) do
        :ok
      else
        invalid("Responses WebSocket limits must be positive integers with known names")
      end
    else
      invalid("Responses WebSocket options must be a keyword list")
    end
  end

  defp validate_options(_), do: invalid("Responses WebSocket options must be a keyword list")

  defp string_keys(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      string_keys(Map.values(value))
    else
      invalid("Native Responses JSON object keys must be strings")
    end
  end

  defp string_keys(values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case string_keys(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp string_keys(_value), do: :ok
  defp invalid(message), do: {:error, Error.invalid!(message)}
end
