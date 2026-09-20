defmodule Backplane.AiProtocol.Codec do
  @moduledoc """
  Pure provider codec facade.

  Supported selectors are `:anthropic`, `:openai`, and `:google`. Request encoding accepts
  `stream: boolean()`. Streaming functions retain state only in the value returned to the caller.
  Transport, authentication, retries, and execution remain host-owned.
  """

  alias Backplane.AiProtocol.{Error, Request, Response, StreamEvent}

  @callback encode_request(Request.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  @callback decode_response(integer(), list(), binary() | map(), keyword()) ::
              {:ok, Response.t()} | {:error, Error.t()}
  @callback decode_error(integer(), list(), binary() | map(), keyword()) :: {:error, Error.t()}
  @callback stream_new(keyword()) :: term()
  @callback stream_feed(term(), binary()) ::
              {:ok, term(), [StreamEvent.t()]} | {:error, Error.t(), term()}
  @callback stream_finish(term(), atom()) ::
              {:ok, term(), [StreamEvent.t()]} | {:error, Error.t(), term()}

  @spec encode_request(atom(), Request.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def encode_request(protocol, request, opts \\ []),
    do: call(protocol, :encode_request, [request, opts])

  @spec decode_response(atom(), integer(), list(), binary() | map(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def decode_response(protocol, status, headers, body, opts \\ []),
    do: call(protocol, :decode_response, [status, headers, body, opts])

  @spec decode_error(atom(), integer(), list(), binary() | map(), keyword()) ::
          {:error, Error.t()}
  def decode_error(protocol, status, headers, body, opts \\ []),
    do: call(protocol, :decode_error, [status, headers, body, opts])

  def stream_new(protocol, opts \\ []), do: call(protocol, :stream_new, [opts])
  def stream_feed(protocol, state, bytes), do: call(protocol, :stream_feed, [state, bytes])
  def stream_finish(protocol, state, reason), do: call(protocol, :stream_finish, [state, reason])

  defp call(protocol, function, args) do
    case implementation(protocol) do
      nil -> {:error, Error.incompatible!("Unsupported provider protocol: #{inspect(protocol)}")}
      module -> apply(module, function, args)
    end
  end

  defp implementation(:anthropic), do: Backplane.AiProtocol.Codec.Anthropic
  defp implementation(:openai), do: Backplane.AiProtocol.Codec.OpenAI
  defp implementation(:google), do: Backplane.AiProtocol.Codec.Google
  defp implementation(_), do: nil
end
