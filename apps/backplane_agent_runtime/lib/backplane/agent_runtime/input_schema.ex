defmodule Backplane.AgentRuntime.InputSchema do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Small dependency-free validator for the runtime tool gateway.

  The supported JSON Schema subset is deliberately strict and recursively
  checked before arguments are validated. Unsupported keywords therefore fail
  before a registered tool backend can be invoked, including keywords in an
  unused object property or composition branch.
  """

  @schema_keys [
    :type,
    :properties,
    :required,
    :additionalProperties,
    :additional_properties,
    :description,
    :enum,
    :minimum,
    :items,
    :oneOf
  ]
  @spec validate(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def validate(schema, input) when is_map(schema) and is_map(input) do
    with :ok <- validate_root_schema(schema),
         :ok <- validate_value(input, schema, "$arguments") do
      {:ok, input}
    end
  end

  def validate(nil, _input) do
    {:error, Error.new(:unsupported_capability, "tool schema is required")}
  end

  def validate(_schema, _input), do: validation("tool schema and arguments must be maps")

  defp validate_root_schema(schema) do
    case {fetch_value(schema, :oneOf), value(schema, :type, "object")} do
      {:error, type} when type in ["object", :object] -> validate_schema(schema, :root)
      _ -> {:error, Error.new(:unsupported_capability, "only object tool schemas are supported")}
    end
  end

  defp validate_schema(schema, position) when is_map(schema) do
    with :ok <- supported_keys(schema, @schema_keys),
         :ok <- validate_enum_schema(schema) do
      case fetch_value(schema, :oneOf) do
        {:ok, branches} -> validate_one_of_schema(schema, branches)
        :error -> validate_typed_schema(schema, position)
      end
    end
  end

  defp validate_schema(_schema, _position), do: validation("property schema must be a map")

  defp validate_enum_schema(schema) do
    case fetch_value(schema, :enum) do
      :error ->
        :ok

      {:ok, choices} ->
        if is_list(choices) and Enum.all?(choices, &json_value?/1),
          do: :ok,
          else: validation("schema enum must be a list of JSON values")
    end
  end

  defp json_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item) end)

  defp json_value?(_value), do: false

  defp validate_one_of_schema(schema, branches) do
    sibling_keys =
      schema
      |> Map.keys()
      |> Enum.reject(&(to_string(&1) in ["oneOf", "description"]))

    cond do
      sibling_keys != [] ->
        {:error,
         Error.new(:unsupported_capability, "oneOf sibling keywords are unsupported",
           details: %{keywords: sibling_keys}
         )}

      not is_list(branches) or branches == [] ->
        validation("schema oneOf must be a non-empty list")

      true ->
        reduce_schemas(branches)
    end
  end

  defp validate_typed_schema(schema, position) do
    default = if position == :root, do: "object", else: nil

    case value(schema, :type, default) do
      type when type in ["object", :object] -> validate_object_schema(schema)
      type when type in ["array", :array] -> validate_array_schema(schema)
      type when type in ["integer", :integer] -> validate_numeric_schema(schema)
      type when type in ["number", :number] -> validate_numeric_schema(schema)
      type when type in ["string", :string, "boolean", :boolean] -> validate_scalar_schema(schema)
      nil -> validation("property schema type is required")
      type -> unsupported_type(type)
    end
  end

  defp validate_object_schema(schema) do
    with {:ok, properties} <- properties(schema),
         {:ok, _required} <- required(schema),
         :ok <- additional_properties(schema),
         :ok <- disallow_keywords(schema, [:minimum, :items]),
         :ok <- reduce_schemas(Map.values(properties)) do
      :ok
    end
  end

  defp validate_array_schema(schema) do
    with :ok <- disallow_keywords(schema, [:properties, :required, :minimum]),
         :ok <- additional_properties_absent(schema) do
      case fetch_value(schema, :items) do
        {:ok, items} -> validate_schema(items, :nested)
        :error -> :ok
      end
    end
  end

  defp validate_numeric_schema(schema) do
    with :ok <- disallow_keywords(schema, [:properties, :required, :items]),
         :ok <- additional_properties_absent(schema) do
      case fetch_value(schema, :minimum) do
        {:ok, minimum} when is_number(minimum) -> :ok
        {:ok, _minimum} -> validation("schema minimum must be a number")
        :error -> :ok
      end
    end
  end

  defp validate_scalar_schema(schema) do
    with :ok <- disallow_keywords(schema, [:properties, :required, :minimum, :items]),
         :ok <- additional_properties_absent(schema) do
      :ok
    end
  end

  defp reduce_schemas(schemas) do
    Enum.reduce_while(schemas, :ok, fn schema, :ok ->
      case validate_schema(schema, :nested) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
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

  defp additional_properties(schema) do
    case value(schema, :additionalProperties, value(schema, :additional_properties, true)) do
      additional? when is_boolean(additional?) -> :ok
      _ -> validation("schema additionalProperties must be a boolean")
    end
  end

  defp additional_properties_absent(schema) do
    disallow_keywords(schema, [:additionalProperties, :additional_properties])
  end

  defp disallow_keywords(schema, keywords) do
    case Enum.find(keywords, &match?({:ok, _}, fetch_value(schema, &1))) do
      nil ->
        :ok

      keyword ->
        {:error,
         Error.new(:unsupported_capability, "schema keyword is unsupported for this type",
           details: %{keyword: keyword}
         )}
    end
  end

  defp validate_value(value, schema, path) do
    with :ok <- validate_shape(value, schema, path) do
      case fetch_value(schema, :enum) do
        :error ->
          :ok

        {:ok, choices} ->
          if Enum.any?(choices, &(&1 == value)),
            do: :ok,
            else: validation("tool argument is not an allowed enum value", %{path: path})
      end
    end
  end

  defp validate_shape(value, schema, path) do
    case fetch_value(schema, :oneOf) do
      {:ok, branches} -> validate_one_of_value(value, branches, path)
      :error -> validate_typed_value(value, schema, path)
    end
  end

  defp validate_one_of_value(value, branches, path) do
    matches = Enum.count(branches, &(validate_value(value, &1, path) == :ok))

    if matches == 1,
      do: :ok,
      else: validation("tool argument must match exactly one oneOf branch", %{path: path})
  end

  defp validate_typed_value(value, schema, path) do
    case value(schema, :type, "object") do
      type when type in ["object", :object] -> validate_object_value(value, schema, path)
      type when type in ["array", :array] -> validate_array_value(value, schema, path)
      type when type in ["integer", :integer] -> validate_integer(value, schema, path)
      type when type in ["number", :number] -> validate_number(value, schema, path)
      type when type in ["string", :string] -> validate_primitive(is_binary(value), type, path)
      type when type in ["boolean", :boolean] -> validate_primitive(is_boolean(value), type, path)
    end
  end

  defp validate_object_value(value, schema, path) when is_map(value) do
    {:ok, properties} = properties(schema)
    {:ok, required} = required(schema)

    with :ok <- validate_required(value, required, path),
         :ok <- validate_additional(value, properties, schema, path) do
      Enum.reduce_while(properties, :ok, fn {name, property_schema}, :ok ->
        case fetch_property(value, name) do
          {:ok, property_value} ->
            case validate_value(property_value, property_schema, property_path(path, name)) do
              :ok -> {:cont, :ok}
              {:error, %Error{} = error} -> {:halt, {:error, error}}
            end

          :error ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp validate_object_value(_value, _schema, path),
    do: validation("tool argument has the wrong type", %{path: path, type: "object"})

  defp validate_array_value(value, schema, path) when is_list(value) do
    case fetch_value(schema, :items) do
      {:ok, items} ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
          case validate_value(item, items, "#{path}[#{index}]") do
            :ok -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)

      :error ->
        :ok
    end
  end

  defp validate_array_value(_value, _schema, path),
    do: validation("tool argument has the wrong type", %{path: path, type: "array"})

  defp validate_integer(value, schema, path) when is_integer(value),
    do: validate_minimum(value, schema, path)

  defp validate_integer(_value, _schema, path),
    do: validation("tool argument has the wrong type", %{path: path, type: "integer"})

  defp validate_number(value, schema, path) when is_number(value),
    do: validate_minimum(value, schema, path)

  defp validate_number(_value, _schema, path),
    do: validation("tool argument has the wrong type", %{path: path, type: "number"})

  defp validate_minimum(value, schema, path) do
    case fetch_value(schema, :minimum) do
      {:ok, minimum} when value < minimum ->
        validation("tool argument is below the minimum", %{path: path, minimum: minimum})

      _ ->
        :ok
    end
  end

  defp validate_primitive(true, _type, _path), do: :ok

  defp validate_primitive(false, type, path),
    do: validation("tool argument has the wrong type", %{path: path, type: type})

  defp validate_required(input, required, path) do
    case Enum.find(required, &(not has_property?(input, &1))) do
      nil ->
        :ok

      property ->
        validation("required tool argument is missing", %{path: path, property: property})
    end
  end

  defp validate_additional(input, properties, schema, path) do
    allowed = properties |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    additional? =
      value(schema, :additionalProperties, value(schema, :additional_properties, true))

    if additional? do
      :ok
    else
      case Enum.find(Map.keys(input), &(not MapSet.member?(allowed, to_string(&1)))) do
        nil ->
          :ok

        property ->
          validation("additional tool argument is not allowed", %{path: path, property: property})
      end
    end
  end

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

  defp unsupported_type(type) do
    {:error,
     Error.new(:unsupported_capability, "property schema type is unsupported",
       details: %{type: type}
     )}
  end

  defp fetch_property(input, name) do
    case Map.fetch(input, name) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(input, to_string(name))
    end
  end

  defp has_property?(input, name), do: match?({:ok, _}, fetch_property(input, name))
  defp property_path(path, name), do: "#{path}.#{name}"

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp value(map, key, default) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp validation(message, details \\ %{}),
    do: {:error, Error.new(:validation, message, details: details)}
end
