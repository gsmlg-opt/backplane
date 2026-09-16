defmodule Backplane.LLM.ModelResponse do
  @moduledoc """
  Restores the client-facing model identifier after alias routing.

  Upstreams receive the resolved model name, but clients expect the model
  identifier they sent in the response.
  """

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
end
