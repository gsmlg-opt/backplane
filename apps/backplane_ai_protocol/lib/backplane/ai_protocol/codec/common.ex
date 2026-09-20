defmodule Backplane.AiProtocol.Codec.Common do
  @moduledoc false

  alias Backplane.AiProtocol.{Error, SSE, Usage}

  def stream_state(opts) do
    %{
      sse: SSE.new(opts),
      terminal?: false,
      done?: false,
      tool_calls: %{},
      opts: opts
    }
  end

  def feed(state, bytes, decoder) when is_binary(bytes) do
    case SSE.feed(state.sse, bytes) do
      {:ok, sse, frames} -> decode_frames(%{state | sse: sse}, frames, decoder, [])
      {:error, error, sse} -> {:error, error, %{state | sse: sse}}
    end
  end

  def feed(state, _bytes, _decoder),
    do: {:error, Error.invalid!("Stream chunk must be binary"), state}

  def finish(state, reason, decoder) do
    case SSE.finish(state.sse) do
      {:ok, sse, frames} ->
        case decode_frames(%{state | sse: sse}, frames, decoder, []) do
          {:ok, state, events} when state.terminal? or state.done? -> {:ok, state, events}
          {:ok, state, _events} -> {:error, incomplete_error(reason), state}
          error -> error
        end

      {:error, error, sse} ->
        {:error, error, %{state | sse: sse}}
    end
  end

  def decode_json(body) when is_map(body), do: {:ok, body}

  def decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, Error.invalid!("Provider response is not a JSON object")}
    end
  end

  def decode_json(_), do: {:error, Error.invalid!("Provider response must be JSON")}

  def error(status, body, provider) do
    {code, _message} = sanitized_error(body)

    {:error,
     %Error{
       kind: error_kind(status),
       stage: :response,
       http_status: status,
       provider_code: code,
       message: "#{provider} provider request failed",
       retry_hint:
         if(status in [408, 429] or status >= 500, do: :retryable, else: :not_retryable),
       upstream_outcome: :known
     }}
  end

  def usage(attrs) do
    case Usage.new(attrs) do
      {:ok, usage} -> {:ok, usage}
      error -> error
    end
  end

  def json_arguments({:structured, value}), do: {:ok, value}

  def json_arguments({:json, value}) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, Error.invalid!("Tool call arguments must be a JSON object")}
    end
  end

  def image(%{"source" => "base64", "media_type" => media_type, "data" => data})
      when is_binary(media_type) and is_binary(data),
      do: {:ok, {media_type, data}}

  def image(_), do: {:error, Error.incompatible!("Unsupported image representation")}

  def text_content(blocks),
    do: blocks |> Enum.map(&(&1.text || to_string(&1.data || ""))) |> Enum.join("\n")

  def tool_result_text(blocks) do
    if Enum.all?(blocks, &(&1.type == :text and is_binary(&1.text))) do
      {:ok, blocks |> Enum.map(& &1.text) |> Enum.join("\n")}
    else
      {:error, Error.incompatible!("Provider cannot preserve non-text tool result content")}
    end
  end

  def reject_reserved(settings, output_constraints, reserved) do
    values = Map.merge(settings || %{}, output_constraints || %{})

    case Enum.find(Map.keys(values), &(to_string(&1) in reserved)) do
      nil -> :ok
      key -> {:error, Error.invalid!("Provider option cannot override core field: #{key}")}
    end
  end

  def reject_state_references(%{provider_state_references: []}), do: :ok
  def reject_state_references(%{provider_state_references: nil}), do: :ok

  def reject_state_references(_request),
    do: {:error, Error.incompatible!("Provider state references require host resolution")}

  def affinity(opts, protocol) do
    %{
      profile: Keyword.get(opts, :profile, protocol),
      protocol: protocol,
      endpoint: Keyword.get(opts, :endpoint),
      account: Keyword.get(opts, :account),
      workspace: Keyword.get(opts, :workspace),
      model: Keyword.get(opts, :model)
    }
  end

  def validate_state_affinity(state, protocol, opts) do
    affinity = state.affinity

    required = [
      {affinity.profile, "origin profile"},
      {affinity.endpoint, "origin endpoint"},
      {affinity.model, "origin model"},
      {Keyword.get(opts, :profile), "destination profile"},
      {Keyword.get(opts, :endpoint), "destination endpoint"},
      {Keyword.get(opts, :model), "destination model"}
    ]

    checks = [
      {state.source_protocol, protocol, "source protocol"},
      {affinity.protocol, protocol, "affinity protocol"},
      {state.source_profile, affinity.profile, "source profile"},
      {Keyword.get(opts, :profile), affinity.profile, "destination profile"},
      {Keyword.get(opts, :endpoint), affinity.endpoint, "destination endpoint"},
      {Keyword.get(opts, :account), affinity.account, "destination account"},
      {Keyword.get(opts, :workspace), affinity.workspace, "destination workspace"},
      {Keyword.get(opts, :model), affinity.model, "destination model"}
    ]

    case Enum.find(required, fn {value, _field} -> not (is_binary(value) and value != "") end) do
      {_value, field} ->
        {:error, Error.incompatible!("Opaque provider state #{field} is required for replay")}

      nil ->
        case Enum.find(checks, fn
               {_actual, nil, _field} -> false
               {actual, expected, _field} -> actual != expected
             end) do
          nil ->
            :ok

          {_actual, _expected, field} ->
            {:error,
             Error.incompatible!("Opaque provider state #{field} does not match its origin")}
        end
    end
  end

  defp decode_frames(state, [], _decoder, acc), do: {:ok, state, Enum.reverse(acc)}

  defp decode_frames(state, [frame | rest], decoder, acc) do
    case decoder.(state, frame) do
      {:ok, state, events} -> decode_frames(state, rest, decoder, Enum.reverse(events, acc))
      {:error, error, state} -> {:error, error, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp incomplete_error(reason),
    do: %Error{
      kind: :upstream_error,
      stage: :response,
      message: "Provider stream ended before completion",
      upstream_outcome: if(reason == :cancelled, do: :unknown, else: :known),
      partial_output: %{}
    }

  defp sanitized_error(%{"error" => error}) when is_map(error),
    do: {safe(error["code"] || error["type"]), safe(error["message"])}

  defp sanitized_error(%{"error" => message}) when is_binary(message), do: {nil, safe(message)}
  defp sanitized_error(_), do: {nil, nil}
  defp safe(value) when is_binary(value), do: String.slice(value, 0, 512)
  defp safe(_), do: nil
  defp error_kind(401), do: :authentication
  defp error_kind(403), do: :authorization
  defp error_kind(404), do: :not_found
  defp error_kind(429), do: :rate_limited
  defp error_kind(status) when status in 400..499, do: :invalid_request
  defp error_kind(_), do: :upstream_error
end
