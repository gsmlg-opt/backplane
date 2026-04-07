defmodule Backplane.LLM.ModelExtractor do
  @moduledoc """
  Extracts and replaces the "model" field in LLM request JSON bodies.
  """

  @doc """
  Parse JSON body and return the model string.

  Returns `{:ok, model_string}` on success, or
  `{:error, :no_model}` if the field is absent or not a string, or
  `{:error, :invalid_json}` if the body is not valid JSON.
  """
  @spec extract(String.t()) :: {:ok, String.t()} | {:error, :no_model | :invalid_json}
  def extract(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"model" => model}} when is_binary(model) ->
        {:ok, model}

      {:ok, _} ->
        {:error, :no_model}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  @doc """
  Parse JSON body, replace the model field with `new_model`, and re-encode.

  Returns `{:ok, new_body}` on success, or `{:error, :invalid_json}` if the
  body is not valid JSON.
  """
  @spec replace_model(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_json}
  def replace_model(body, new_model) when is_binary(body) and is_binary(new_model) do
    case Jason.decode(body) do
      {:ok, map} ->
        new_body = Jason.encode!(Map.put(map, "model", new_model))
        {:ok, new_body}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end
end
