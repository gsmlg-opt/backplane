defmodule Backplane.LLM.Google.RequestBody do
  @moduledoc false

  def prepare(operation, raw_body, _requested_model, _resolved_model)
      when operation in [:generate, :stream_generate] do
    with {:ok, body} <- decode_map(raw_body),
         false <- Map.has_key?(body, "model") do
      {:ok, raw_body}
    else
      true -> {:error, :body_model_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare(:count_tokens, raw_body, requested_model, resolved_model) do
    with {:ok, body} <- decode_map(raw_body),
         {:ok, body} <- normalize_nested_model(body, requested_model, resolved_model) do
      if body == elem(Jason.decode(raw_body), 1),
        do: {:ok, raw_body},
        else: {:ok, Jason.encode!(body)}
    end
  end

  defp decode_map(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> {:error, :invalid_json}
    end
  end

  defp normalize_nested_model(%{"generateContentRequest" => request} = body, requested, resolved)
       when is_map(request) do
    case Map.get(request, "model") do
      nil ->
        {:ok, body}

      model when is_binary(model) ->
        accepted = [requested, "models/" <> requested, resolved, "models/" <> resolved]

        if model in accepted do
          {:ok,
           put_in(body, ["generateContentRequest", "model"], "models/" <> trim_models(resolved))}
        else
          {:error, :body_model_conflict}
        end

      _other ->
        {:error, :body_model_conflict}
    end
  end

  defp normalize_nested_model(body, _requested, _resolved), do: {:ok, body}
  defp trim_models(model), do: String.trim_leading(model, "models/")
end
