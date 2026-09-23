defmodule Backplane.LLM.Google.RequestTarget do
  @moduledoc false

  @model ~r/^[A-Za-z0-9][A-Za-z0-9._~-]*$/
  @operations %{
    "generateContent" => :generate,
    "streamGenerateContent" => :stream_generate,
    "countTokens" => :count_tokens
  }

  defstruct [:model, :operation, :upstream_operation]

  @type operation :: :generate | :stream_generate | :count_tokens | :models_list | :models_get

  def parse("GET", "/v1beta/models", _query),
    do: {:ok, %__MODULE__{operation: :models_list}}

  def parse("GET", "/v1beta/models/" <> model, _query) do
    with :ok <- validate_model(model) do
      {:ok, %__MODULE__{model: model, operation: :models_get}}
    end
  end

  def parse("POST", "/v1beta/models/" <> target, query) do
    with [model, operation_name] <- String.split(target, ":"),
         :ok <- validate_model(model),
         {:ok, operation} <- fetch_operation(operation_name),
         :ok <- validate_stream_query(operation, query) do
      {:ok,
       %__MODULE__{
         model: model,
         operation: operation,
         upstream_operation: operation_name
       }}
    else
      [_single] -> {:error, :unsupported_route}
      parts when is_list(parts) -> {:error, :invalid_model}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unsupported_route}
    end
  end

  def parse(_method, path, _query) do
    if String.starts_with?(path, "/v1beta/models/"),
      do: {:error, :unsupported_route},
      else: {:error, :unsupported_route}
  end

  def upstream_path(operation, model) do
    with {:ok, model} <- normalize_model(model) do
      {:ok, "/models/#{model}:#{operation_name(operation)}"}
    end
  end

  def normalize_model("models/" <> model), do: normalize_bare_model(model)
  def normalize_model(model), do: normalize_bare_model(model)

  def valid_model?(model) when is_binary(model), do: Regex.match?(@model, model)
  def valid_model?(_model), do: false

  defp normalize_bare_model(model) do
    if valid_model?(model), do: {:ok, model}, else: {:error, :invalid_model}
  end

  defp fetch_operation(name) do
    case Map.fetch(@operations, name) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, :unsupported_operation}
    end
  end

  defp validate_model(model) do
    if valid_model?(model), do: :ok, else: {:error, :invalid_model}
  end

  defp validate_stream_query(:stream_generate, query) do
    params = URI.decode_query(query)
    if params["alt"] == "sse", do: :ok, else: {:error, :stream_requires_sse}
  rescue
    ArgumentError -> {:error, :stream_requires_sse}
  end

  defp validate_stream_query(_operation, _query), do: :ok

  defp operation_name(:generate), do: "generateContent"
  defp operation_name(:stream_generate), do: "streamGenerateContent"
  defp operation_name(:count_tokens), do: "countTokens"
end
