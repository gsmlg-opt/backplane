defmodule Backplane.Registry.InputValidator do
  @moduledoc """
  Lightweight JSON Schema validation for MCP tool call arguments.

  Validates required fields and basic type constraints from the tool's
  input_schema. Not a full JSON Schema validator — only covers the
  subset used by MCP tool definitions.
  """

  @doc """
  Validate arguments against a tool's input schema.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(map(), map()) :: :ok | {:error, String.t()}
  def validate(args, schema) when is_map(args) and is_map(schema) do
    with :ok <- validate_required(args, schema) do
      validate_types(args, schema)
    end
  end

  def validate(_args, _schema), do: :ok

  defp validate_required(args, schema) do
    required = Map.get(schema, "required", [])
    missing = Enum.reject(required, &Map.has_key?(args, &1))

    case missing do
      [] -> :ok
      fields -> {:error, "Missing required arguments: #{Enum.join(fields, ", ")}"}
    end
  end

  defp validate_types(args, schema) do
    properties = Map.get(schema, "properties", %{})

    Enum.reduce_while(args, :ok, fn {key, value}, :ok ->
      properties |> Map.get(key) |> check_type(key, value)
    end)
  end

  defp check_type(%{"type" => expected_type}, key, value) do
    if type_matches?(value, expected_type) do
      {:cont, :ok}
    else
      {:halt, {:error, "Argument '#{key}' must be #{expected_type}, got #{inspect_type(value)}"}}
    end
  end

  defp check_type(_property, _key, _value), do: {:cont, :ok}

  defp type_matches?(value, "string") when is_binary(value), do: true
  defp type_matches?(value, "integer") when is_integer(value), do: true
  defp type_matches?(value, "number") when is_number(value), do: true
  defp type_matches?(value, "boolean") when is_boolean(value), do: true
  defp type_matches?(value, "object") when is_map(value), do: true
  defp type_matches?(value, "array") when is_list(value), do: true
  defp type_matches?(nil, _type), do: true
  defp type_matches?(_value, _type), do: false

  defp inspect_type(value) when is_binary(value), do: "string"
  defp inspect_type(value) when is_integer(value), do: "integer"
  defp inspect_type(value) when is_float(value), do: "number"
  defp inspect_type(value) when is_boolean(value), do: "boolean"
  defp inspect_type(value) when is_map(value), do: "object"
  defp inspect_type(value) when is_list(value), do: "array"
  defp inspect_type(nil), do: "null"
  defp inspect_type(_), do: "unknown"
end
