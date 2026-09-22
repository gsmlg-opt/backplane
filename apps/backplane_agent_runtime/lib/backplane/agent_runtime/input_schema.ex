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
    :default,
    :enum,
    :minimum,
    :items,
    :oneOf,
    :anyOf
  ]

  @spec validate_schema(term()) :: :ok | {:error, Error.t()}
  def validate_schema(schema) when is_map(schema), do: validate_root_schema(schema)

  def validate_schema(_schema),
    do: {:error, Error.new(:validation, "tool schema must be a map")}

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
    case value(schema, :type, "object") do
      type when type in ["object", :object] -> validate_schema(schema, :root)
      _ -> {:error, Error.new(:unsupported_capability, "only object tool schemas are supported")}
    end
  end

  defp validate_schema(schema, position) when is_map(schema) do
    with :ok <- supported_keys(schema, @schema_keys),
         :ok <- validate_description(schema),
         :ok <- validate_enum_schema(schema) do
      case {fetch_value(schema, :oneOf), fetch_value(schema, :anyOf)} do
        {{:ok, _one_of_branches}, {:ok, _any_of_branches}} ->
          {:error,
           Error.new(:unsupported_capability, "combining schema compositions is unsupported")}

        {{:ok, branches}, :error} ->
          validate_one_of_schema(schema, branches, position)

        {:error, {:ok, branches}} ->
          validate_any_of_schema(schema, branches, position)

        {:error, :error} ->
          validate_typed_schema(schema, position)
      end
    end
  end

  defp validate_schema(_schema, _position), do: validation("property schema must be a map")

  defp validate_description(schema) do
    case fetch_value(schema, :description) do
      :error -> :ok
      {:ok, description} when is_binary(description) -> :ok
      {:ok, _description} -> validation("schema description must be a string")
    end
  end

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

  defp validate_one_of_schema(schema, branches, position) do
    sibling_schema = delete_value(schema, :oneOf)

    sibling_keys =
      sibling_schema
      |> Map.keys()
      |> Enum.reject(&(schema_key(&1) in ["description", "default"]))

    cond do
      not is_list(branches) or branches == [] ->
        validation("schema oneOf must be a non-empty list")

      sibling_keys == [] and position not in [:root, :object_branch] ->
        reduce_schemas(branches)

      not object_schema?(sibling_schema, position) ->
        {:error,
         Error.new(:unsupported_capability, "oneOf sibling keywords are unsupported",
           details: %{keywords: sibling_keys}
         )}

      true ->
        with :ok <- validate_typed_schema(sibling_schema, position),
             :ok <- reduce_schemas(branches, :object_branch) do
          :ok
        end
    end
  end

  defp object_schema?(schema, position) do
    position in [:root, :object_branch] or value(schema, :type, nil) in ["object", :object]
  end

  defp validate_any_of_schema(schema, branches, position) do
    sibling_schema = delete_value(schema, :anyOf)

    cond do
      not is_list(branches) or branches == [] ->
        validation("schema anyOf must be a non-empty list")

      true ->
        branch_position =
          if value(sibling_schema, :type, if(position == :root, do: "object")) in [
               "object",
               :object
             ],
             do: :object_branch,
             else: :nested

        with :ok <- validate_typed_schema(sibling_schema, position),
             :ok <- reduce_schemas(branches, branch_position) do
          :ok
        end
    end
  end

  defp validate_typed_schema(schema, position) do
    default = if position in [:root, :object_branch], do: "object", else: nil

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

  defp reduce_schemas(schemas, position \\ :nested) do
    Enum.reduce_while(schemas, :ok, fn schema, :ok ->
      case validate_schema(schema, position) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp properties(schema) do
    case value(schema, :properties, %{}) do
      properties when is_map(properties) ->
        if Enum.all?(Map.keys(properties), &(not is_nil(schema_key(&1)))),
          do: {:ok, properties},
          else: validation("schema property names must be strings or atoms")

      _ ->
        validation("schema properties must be a map")
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
    case {fetch_value(schema, :oneOf), fetch_value(schema, :anyOf)} do
      {{:ok, branches}, :error} ->
        sibling_schema = delete_value(schema, :oneOf)

        with :ok <- validate_one_of_sibling_value(value, sibling_schema, path) do
          validate_one_of_value(value, branches, path)
        end

      {:error, {:ok, branches}} ->
        with :ok <- validate_typed_value(value, delete_value(schema, :anyOf), path) do
          validate_any_of_value(value, branches, path)
        end

      {:error, :error} ->
        validate_typed_value(value, schema, path)
    end
  end

  defp validate_one_of_sibling_value(value, schema, path) do
    if Enum.all?(Map.keys(schema), &(schema_key(&1) in ["description", "default"])) do
      :ok
    else
      validate_typed_value(value, schema, path)
    end
  end

  defp validate_one_of_value(value, branches, path) do
    matches = Enum.count(branches, &(validate_value(value, &1, path) == :ok))

    if matches == 1,
      do: :ok,
      else: validation("tool argument must match exactly one oneOf branch", %{path: path})
  end

  defp validate_any_of_value(value, branches, path) do
    if Enum.any?(branches, &(validate_value(value, &1, path) == :ok)),
      do: :ok,
      else: validation("tool argument must match at least one anyOf branch", %{path: path})
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
    allowed = properties |> Map.keys() |> Enum.map(&schema_key/1) |> MapSet.new()

    additional? =
      value(schema, :additionalProperties, value(schema, :additional_properties, true))

    if additional? do
      :ok
    else
      case Enum.find(Map.keys(input), &(not MapSet.member?(allowed, schema_key(&1)))) do
        nil ->
          :ok

        property ->
          validation("additional tool argument is not allowed", %{path: path, property: property})
      end
    end
  end

  defp supported_keys(map, allowed) when is_map(map) do
    allowed = allowed |> Enum.map(&schema_key/1) |> MapSet.new()

    case Enum.find(Map.keys(map), &(not MapSet.member?(allowed, schema_key(&1)))) do
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

  defp delete_value(map, key), do: map |> Map.delete(key) |> Map.delete(Atom.to_string(key))

  defp schema_key(key) when is_binary(key), do: key
  defp schema_key(key) when is_atom(key), do: Atom.to_string(key)
  defp schema_key(_key), do: nil

  defp validation(message, details \\ %{}),
    do: {:error, Error.new(:validation, message, details: details)}
end
