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

  def validate(args, _schema) when not is_map(args) do
    {:error, "Arguments must be an object, got #{inspect_type(args)}"}
  end

  def validate(_args, _schema), do: :ok

  defp validate_required(args, schema) do
    required = Map.get(schema, "required", [])

    missing =
      Enum.reject(required, fn key ->
        Map.has_key?(args, key) and not is_nil(Map.get(args, key))
      end)

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

  defp check_type(%{"type" => expected_type} = property, key, value) do
    with true <- type_matches?(value, expected_type),
         :ok <- check_enum(property, key, value),
         :ok <- check_constraints(property, key, value) do
      {:cont, :ok}
    else
      false ->
        {:halt,
         {:error, "Argument '#{key}' must be #{expected_type}, got #{inspect_type(value)}"}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  defp check_type(_property, _key, _value), do: {:cont, :ok}

  defp check_enum(%{"enum" => valid_values}, key, value) when is_list(valid_values) do
    if value in valid_values do
      :ok
    else
      {:error,
       "Argument '#{key}' must be one of: #{Enum.map_join(valid_values, ", ", &inspect/1)}"}
    end
  end

  defp check_enum(_property, _key, _value), do: :ok

  defp check_constraints(property, key, value) when is_number(value) do
    cond do
      is_number(property["minimum"]) and value < property["minimum"] ->
        {:error, "Argument '#{key}' must be >= #{property["minimum"]}"}

      is_number(property["maximum"]) and value > property["maximum"] ->
        {:error, "Argument '#{key}' must be <= #{property["maximum"]}"}

      true ->
        :ok
    end
  end

  defp check_constraints(property, key, value) when is_binary(value) do
    cond do
      is_integer(property["minLength"]) and String.length(value) < property["minLength"] ->
        {:error, "Argument '#{key}' must have length >= #{property["minLength"]}"}

      is_integer(property["maxLength"]) and String.length(value) > property["maxLength"] ->
        {:error, "Argument '#{key}' must have length <= #{property["maxLength"]}"}

      true ->
        :ok
    end
  end

  defp check_constraints(_property, _key, _value), do: :ok

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
