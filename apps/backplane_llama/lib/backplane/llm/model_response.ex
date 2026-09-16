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
    case Jason.decode(body) do
      {:ok, response} when is_map(response) ->
        normalized = replace_top_level_model(response, requested_model, resolved_model)
        if normalized == response, do: body, else: Jason.encode!(normalized)

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
    case Jason.decode(body) do
      {:ok, response} when is_map(response) ->
        normalized = replace_responses_models(response, requested_model, resolved_model)
        if normalized == response, do: body, else: Jason.encode!(normalized)

      _ ->
        body
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
      case Jason.decode(payload) do
        {:ok, response} when is_map(response) ->
          normalized = replace_responses_models(response, requested_model, resolved_model)

          if normalized == response do
            line
          else
            "data: " <> Jason.encode!(normalized) <> suffix
          end

        _ ->
          line
      end
    end)
  end

  @doc "Builds a per-request mapper that handles SSE lines split across transport chunks."
  @spec responses_stream_mapper(binary(), binary()) :: (binary() -> [binary()])
  def responses_stream_mapper(model, model) when is_binary(model) do
    fn chunk -> [chunk] end
  end

  def responses_stream_mapper(requested_model, resolved_model)
      when is_binary(requested_model) and is_binary(resolved_model) do
    state_key = {__MODULE__, :responses_stream, make_ref()}

    fn chunk ->
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
    case Jason.decode(payload) do
      {:ok, response} when is_map(response) ->
        normalized = replace_top_level_model(response, requested_model, resolved_model)

        if normalized == response do
          line
        else
          "data: " <> Jason.encode!(normalized) <> suffix
        end

      _ ->
        line
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
