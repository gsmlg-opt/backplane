defmodule Backplane.LLM.ModelResponse do
  @moduledoc """
  Restores the client-facing model identifier after alias routing.

  Upstreams receive the resolved model name, but clients expect the model
  identifier they sent in the response.
  """

  @max_sse_line_bytes 1_048_576

  @doc "Replaces a top-level JSON response model when routing changed."
  @spec normalize_body(binary(), binary(), binary()) :: binary()
  def normalize_body(body, model, model) when is_binary(body) and is_binary(model), do: body

  def normalize_body(body, requested_model, resolved_model)
      when is_binary(body) and is_binary(requested_model) and is_binary(resolved_model) do
    case Formata.JSON.decode(body) do
      {:ok, response} when is_map(response) ->
        normalized = replace_top_level_model(response, requested_model, resolved_model)
        if normalized == response, do: body, else: Formata.JSON.encode!(normalized)

      _ ->
        body
    end
  end

  @doc "Replaces top-level and Responses `response.model` fields in a JSON response."
  @spec normalize_responses_body(binary(), binary(), binary()) :: binary()
  def normalize_responses_body(body, model, model) when is_binary(body) and is_binary(model),
    do: body

  def normalize_responses_body(body, requested_model, resolved_model)
      when is_binary(body) and is_binary(requested_model) and is_binary(resolved_model) do
    case Formata.JSON.decode(body) do
      {:ok, response} when is_map(response) ->
        normalized = replace_responses_models(response, requested_model, resolved_model)
        if normalized == response, do: body, else: Formata.JSON.encode!(normalized)

      _ ->
        body
    end
  end

  @doc "Replaces protocol-defined model fields in a non-streaming JSON response."
  @spec normalize_body_for_protocol(binary(), atom(), binary(), binary()) :: binary()
  def normalize_body_for_protocol(body, _protocol, model, model)
      when is_binary(body) and is_binary(model),
      do: body

  def normalize_body_for_protocol(body, :openai_responses, requested_model, resolved_model),
    do: normalize_responses_body(body, requested_model, resolved_model)

  def normalize_body_for_protocol(body, :anthropic_messages, requested_model, resolved_model),
    do: normalize_anthropic_body(body, requested_model, resolved_model)

  def normalize_body_for_protocol(body, _protocol, requested_model, resolved_model),
    do: normalize_body(body, requested_model, resolved_model)

  @doc "Replaces top-level and Anthropic `message.model` fields in a JSON response."
  @spec normalize_anthropic_body(binary(), binary(), binary()) :: binary()
  def normalize_anthropic_body(body, model, model) when is_binary(body) and is_binary(model),
    do: body

  def normalize_anthropic_body(body, requested_model, resolved_model)
      when is_binary(body) and is_binary(requested_model) and is_binary(resolved_model) do
    case Formata.JSON.decode(body) do
      {:ok, response} when is_map(response) ->
        normalized = replace_anthropic_models(response, requested_model, resolved_model)
        if normalized == response, do: body, else: Formata.JSON.encode!(normalized)

      _ ->
        body
    end
  end

  @doc "Replaces protocol-defined model fields in a single SSE line, preserving exact bytes otherwise."
  @spec normalize_sse_line(binary(), atom(), binary(), binary()) :: binary()
  def normalize_sse_line(line, _protocol, model, model) when is_binary(line) and is_binary(model),
    do: line

  def normalize_sse_line(line, protocol, requested_model, resolved_model)
      when is_binary(line) and is_binary(requested_model) and is_binary(resolved_model) do
    case split_sse_data_line(line) do
      {:ok, prefix, payload, suffix} ->
        case Formata.JSON.decode(payload) do
          {:ok, response} when is_map(response) ->
            normalized = replace_for_protocol(response, protocol, requested_model, resolved_model)

            if normalized == response do
              line
            else
              prefix <> Formata.JSON.encode!(normalized) <> suffix
            end

          _ ->
            line
        end

      :passthrough ->
        line
    end
  end

  @doc "Replaces top-level model fields in SSE data events."
  @spec normalize_chunk(binary(), binary(), binary()) :: binary()
  def normalize_chunk(chunk, model, model) when is_binary(chunk) and is_binary(model), do: chunk

  def normalize_chunk(chunk, requested_model, resolved_model)
      when is_binary(chunk) and is_binary(requested_model) and is_binary(resolved_model) do
    Regex.replace(~r/(?m)^data: ([^\r\n]*)(\r?\n|$)/, chunk, fn line, payload, suffix ->
      normalize_sse_line(line, payload, suffix, requested_model, resolved_model)
    end)
  end

  @doc "Replaces top-level and Responses `response.model` fields in SSE data events."
  @spec normalize_responses_chunk(binary(), binary(), binary()) :: binary()
  def normalize_responses_chunk(chunk, model, model) when is_binary(chunk) and is_binary(model),
    do: chunk

  def normalize_responses_chunk(chunk, requested_model, resolved_model)
      when is_binary(chunk) and is_binary(requested_model) and is_binary(resolved_model) do
    Regex.replace(~r/(?m)^data: ([^\r\n]*)(\r?\n|$)/, chunk, fn line, payload, suffix ->
      case Formata.JSON.decode(payload) do
        {:ok, response} when is_map(response) ->
          normalized = replace_responses_models(response, requested_model, resolved_model)

          if normalized == response do
            line
          else
            "data: " <> Formata.JSON.encode!(normalized) <> suffix
          end

        _ ->
          line
      end
    end)
  end

  @doc "Builds a per-request mapper for split SSE lines; `:eof` flushes any unfinished bytes."
  @spec responses_stream_mapper(binary(), binary()) :: (binary() | :eof -> [binary()])
  def responses_stream_mapper(model, model) when is_binary(model) do
    fn
      :eof -> []
      chunk -> [chunk]
    end
  end

  def responses_stream_mapper(requested_model, resolved_model)
      when is_binary(requested_model) and is_binary(resolved_model) do
    state_key = {__MODULE__, :responses_stream, make_ref()}

    fn
      :eof ->
        {buffer, _} = Process.get(state_key, {"", false})
        Process.delete(state_key)
        if buffer == "", do: [], else: [buffer]

      chunk ->
        {mapped, state} =
          map_stream_chunk(
            Process.get(state_key, {"", false}),
            chunk,
            requested_model,
            resolved_model
          )

        if state == {"", false} do
          Process.delete(state_key)
        else
          Process.put(state_key, state)
        end

        mapped
    end
  end

  defp normalize_sse_line(line, payload, suffix, requested_model, resolved_model) do
    case Formata.JSON.decode(payload) do
      {:ok, response} when is_map(response) ->
        normalized = replace_top_level_model(response, requested_model, resolved_model)

        if normalized == response do
          line
        else
          "data: " <> Formata.JSON.encode!(normalized) <> suffix
        end

      _ ->
        line
    end
  end

  defp replace_for_protocol(response, :openai_responses, requested_model, resolved_model),
    do: replace_responses_models(response, requested_model, resolved_model)

  defp replace_for_protocol(response, :anthropic_messages, requested_model, resolved_model),
    do: replace_anthropic_models(response, requested_model, resolved_model)

  defp replace_for_protocol(response, _protocol, requested_model, resolved_model),
    do: replace_top_level_model(response, requested_model, resolved_model)

  defp replace_anthropic_models(response, requested_model, resolved_model) do
    response = replace_top_level_model(response, requested_model, resolved_model)

    case response do
      %{"message" => nested} when is_map(nested) ->
        Map.put(
          response,
          "message",
          replace_top_level_model(nested, requested_model, resolved_model)
        )

      _ ->
        response
    end
  end

  defp split_sse_data_line(line) do
    {body, suffix} = split_line_ending(line)

    case body do
      "data: " <> payload -> {:ok, "data: ", payload, suffix}
      "data:" <> payload -> {:ok, "data:", payload, suffix}
      _ -> :passthrough
    end
  end

  defp split_line_ending(line) do
    size = byte_size(line)

    cond do
      size >= 2 and binary_part(line, size - 2, 2) == "\r\n" ->
        {binary_part(line, 0, size - 2), "\r\n"}

      size >= 1 and binary_part(line, size - 1, 1) == "\n" ->
        {binary_part(line, 0, size - 1), "\n"}

      true ->
        {line, ""}
    end
  end

  defp replace_top_level_model(
         %{"model" => resolved_model} = response,
         requested_model,
         resolved_model
       ),
       do: Map.put(response, "model", requested_model)

  defp replace_top_level_model(response, _requested_model, _resolved_model), do: response

  defp replace_responses_models(response, requested_model, resolved_model) do
    response = replace_top_level_model(response, requested_model, resolved_model)

    case response do
      %{"response" => nested} when is_map(nested) ->
        Map.put(
          response,
          "response",
          replace_top_level_model(nested, requested_model, resolved_model)
        )

      _ ->
        response
    end
  end

  defp map_stream_chunk({buffer, passthrough?}, chunk, requested_model, resolved_model) do
    map_complete_lines(
      buffer <> chunk,
      passthrough?,
      requested_model,
      resolved_model,
      []
    )
  end

  defp map_complete_lines(data, passthrough?, requested_model, resolved_model, mapped) do
    case :binary.match(data, "\n") do
      {newline, 1} ->
        line = binary_part(data, 0, newline + 1)
        rest = binary_part(data, newline + 1, byte_size(data) - newline - 1)

        mapped_line =
          if passthrough? do
            line
          else
            normalize_responses_chunk(line, requested_model, resolved_model)
          end

        map_complete_lines(rest, false, requested_model, resolved_model, [mapped_line | mapped])

      :nomatch when byte_size(data) > @max_sse_line_bytes ->
        {Enum.reverse([data | mapped]), {"", true}}

      :nomatch ->
        {Enum.reverse(mapped), {data, passthrough?}}
    end
  end
end
