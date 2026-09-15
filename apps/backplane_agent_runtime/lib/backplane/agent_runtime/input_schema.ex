defmodule Backplane.AgentRuntime.InputSchema do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Small dependency-free validator for the runtime tool gateway.

  It supports object schemas with required properties, primitive property
  types, and explicit additional-property control. Other JSON Schema keywords
  are rejected instead of being silently ignored.
  """

  @schema_keys [:type, :properties, :required, :additionalProperties, :additional_properties]
  @property_keys [:type, :description]
  @types ["string", "integer", "number", "boolean", "object", "array"]

  @spec validate(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(schema, input) when is_map(schema) and is_map(input) do
    with :ok <- supported_keys(schema, @schema_keys),
         :ok <- object_type(schema),
         {:ok, properties} <- properties(schema),
         {:ok, required} <- required(schema),
         :ok <- validate_required(input, required),
         :ok <- validate_additional(input, properties, schema),
         :ok <- validate_properties(input, properties) do
      {:ok, input}
    end
  end

  def validate(nil, _input) do
    {:error, Error.new(:unsupported_capability, "tool schema is required")}
  end

  def validate(_schema, _input), do: validation("tool schema and arguments must be maps")

  defp object_type(schema) do
    case value(schema, :type, "object") do
      type when type in ["object", :object] -> :ok
      _ -> {:error, Error.new(:unsupported_capability, "only object tool schemas are supported")}
    end
  end

  defp properties(schema) do
    case value(schema, :properties, %{}) do
      properties when is_map(properties) -> {:ok, properties}
      _ -> validation("schema properties must be a map")
    end
  end

  defp required(schema) do
    case value(schema, :required, []) do
      required when is_list(required) ->
        if Enum.all?(required, &is_binary/1),
          do: {:ok, required},
          else: validation("schema required must be a list of property names")

      _ ->
        validation("schema required must be a list of property names")
    end
  end

  defp validate_required(input, required) do
    case Enum.find(required, &(not has_property?(input, &1))) do
      nil -> :ok
      property -> validation("required tool argument is missing", %{property: property})
    end
  end

  defp validate_additional(input, properties, schema) do
    allowed = properties |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    additional? =
      value(schema, :additionalProperties, value(schema, :additional_properties, true))

    cond do
      not is_boolean(additional?) ->
        validation("schema additionalProperties must be a boolean")

      additional? ->
        :ok

      true ->
        case Enum.find(Map.keys(input), &(not MapSet.member?(allowed, to_string(&1)))) do
          nil -> :ok
          property -> validation("additional tool argument is not allowed", %{property: property})
        end
    end
  end

  defp validate_properties(input, properties) do
    Enum.reduce_while(properties, :ok, fn {name, property_schema}, :ok ->
      with :ok <- supported_property(property_schema),
           {:ok, property_value} <- fetch_property(input, name) do
        case validate_type(property_value, value(property_schema, :type, nil)) do
          :ok -> {:cont, :ok}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      else
        :missing -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp supported_property(schema) when is_map(schema), do: supported_keys(schema, @property_keys)
  defp supported_property(_schema), do: validation("property schema must be a map")

  defp validate_type(_value, nil), do: validation("property schema type is required")
  defp validate_type(value, type) when type in ["string", :string] and is_binary(value), do: :ok

  defp validate_type(value, type) when type in ["integer", :integer] and is_integer(value),
    do: :ok

  defp validate_type(value, type) when type in ["number", :number] and is_number(value), do: :ok

  defp validate_type(value, type) when type in ["boolean", :boolean] and is_boolean(value),
    do: :ok

  defp validate_type(value, type) when type in ["object", :object] and is_map(value), do: :ok
  defp validate_type(value, type) when type in ["array", :array] and is_list(value), do: :ok

  defp validate_type(_value, type)
       when type in @types or type in [:string, :integer, :number, :boolean, :object, :array],
       do: validation("tool argument has the wrong type", %{type: type})

  defp validate_type(_value, type),
    do:
      {:error,
       Error.new(:unsupported_capability, "property schema type is unsupported",
         details: %{type: type}
       )}

  defp supported_keys(map, allowed) when is_map(map) do
    allowed = allowed |> Enum.map(&to_string/1) |> MapSet.new()

    case Enum.find(Map.keys(map), &(not MapSet.member?(allowed, to_string(&1)))) do
      nil ->
        :ok

      key ->
        {:error,
         Error.new(:unsupported_capability, "schema keyword is unsupported",
           details: %{keyword: key}
         )}
    end
  end

  defp fetch_property(input, name) do
    case Map.fetch(input, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(input, to_string(name))
    end
  end

  defp has_property?(input, name), do: match?({:ok, _}, fetch_property(input, name))

  defp value(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp validation(message, details \\ %{}),
    do: {:error, Error.new(:validation, message, details: details)}
end
