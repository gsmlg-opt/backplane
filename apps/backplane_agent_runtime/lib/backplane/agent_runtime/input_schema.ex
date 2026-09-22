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
    :maximum,
    :minLength,
    :minItems,
    :maxItems,
    :pattern,
    :items,
    :oneOf,
    :anyOf,
    :not,
    :format,
    :contentEncoding,
    :"$schema",
    :"x-mcp-header"
  ]

  @type_names ~w(object array string integer number boolean null)
  @string_annotations [:description, :format, :contentEncoding, :"$schema", :"x-mcp-header"]
  @escaped_pattern_characters ~c"\\.^$|?*+()[]{}-/"
  @max_pattern_bytes 1_024
  @pattern_match_limit 100_000

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
    case fetch_value(schema, :type) do
      :error -> validate_schema(schema, :root)
      {:ok, type} when type in ["object", :object] -> validate_schema(schema, :root)
      {:ok, [type]} when type in ["object", :object] -> validate_schema(schema, :root)
      _ -> {:error, Error.new(:unsupported_capability, "only object tool schemas are supported")}
    end
  end

  defp validate_schema(schema, position) when is_map(schema) do
    with :ok <- supported_keys(schema, @schema_keys),
         :ok <- validate_annotations(schema),
         :ok <- validate_type_schema(schema),
         :ok <- validate_enum_schema(schema),
         :ok <- validate_number_keyword(schema, :minimum),
         :ok <- validate_number_keyword(schema, :maximum),
         :ok <- validate_non_negative_integer_keyword(schema, :minLength),
         :ok <- validate_non_negative_integer_keyword(schema, :minItems),
         :ok <- validate_non_negative_integer_keyword(schema, :maxItems),
         :ok <- validate_pattern_schema(schema),
         :ok <- validate_properties_schema(schema),
         :ok <- validate_required_schema(schema),
         :ok <- validate_additional_properties_schema(schema),
         :ok <- validate_child_schema(schema, :items),
         :ok <- validate_child_schema(schema, :not),
         :ok <- validate_composition_schema(schema, :oneOf, position),
         :ok <- validate_composition_schema(schema, :anyOf, position),
         :ok <- validate_composition_combination(schema) do
      :ok
    end
  end

  defp validate_schema(_schema, _position), do: validation("property schema must be a map")

  defp validate_annotations(schema) do
    Enum.reduce_while(@string_annotations, :ok, fn keyword, :ok ->
      case fetch_value(schema, keyword) do
        :error ->
          {:cont, :ok}

        {:ok, annotation} when is_binary(annotation) ->
          {:cont, :ok}

        {:ok, _annotation} ->
          {:halt, validation("schema #{schema_key(keyword)} must be a string")}
      end
    end)
  end

  defp validate_type_schema(schema) do
    case fetch_value(schema, :type) do
      :error ->
        :ok

      {:ok, type} when is_binary(type) or is_atom(type) ->
        validate_type_name(type)

      {:ok, types} when is_list(types) and types != [] ->
        normalized = Enum.map(types, &schema_key/1)

        with true <- Enum.all?(types, &(is_binary(&1) or is_atom(&1))),
             true <- length(normalized) == length(Enum.uniq(normalized)),
             true <- Enum.all?(types, &(validate_type_name(&1) == :ok)) do
          :ok
        else
          _ -> validation("schema type must be a supported type or non-empty unique list")
        end

      {:ok, _type} ->
        validation("schema type must be a supported type or non-empty unique list")
    end
  end

  defp validate_type_name(type) do
    if schema_key(type) in @type_names, do: :ok, else: unsupported_type(type)
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

  defp validate_number_keyword(schema, keyword) do
    case fetch_value(schema, keyword) do
      :error -> :ok
      {:ok, number} when is_number(number) -> :ok
      {:ok, _number} -> validation("schema #{schema_key(keyword)} must be a number")
    end
  end

  defp validate_non_negative_integer_keyword(schema, keyword) do
    case fetch_value(schema, keyword) do
      :error -> :ok
      {:ok, count} when is_integer(count) and count >= 0 -> :ok
      {:ok, _count} -> validation("schema #{schema_key(keyword)} must be a non-negative integer")
    end
  end

  defp validate_pattern_schema(schema) do
    case fetch_value(schema, :pattern) do
      :error ->
        :ok

      {:ok, pattern} when is_binary(pattern) ->
        cond do
          byte_size(pattern) > @max_pattern_bytes ->
            validation("schema pattern exceeds the supported size")

          not portable_pattern?(pattern) ->
            validation("schema pattern uses unsupported syntax")

          true ->
            case compile_pattern(pattern) do
              {:ok, _regex} -> :ok
              {:error, _reason} -> validation("schema pattern must be a valid regular expression")
            end
        end

      {:ok, _pattern} ->
        validation("schema pattern must be a string")
    end
  end

  defp portable_pattern?(pattern) do
    allowed_group? = not String.contains?(String.replace(pattern, "(?:", ""), "(?")

    allowed_escapes? =
      Regex.scan(~r/\\(.)/us, pattern, capture: :all_but_first)
      |> List.flatten()
      |> Enum.all?(fn <<character::utf8>> -> character in @escaped_pattern_characters end)

    allowed_group? and allowed_escapes? and
      not String.contains?(pattern, ["(*", "*+", "++", "?+", "}+", "[[:"])
  end

  defp compile_pattern(pattern), do: pattern |> translate_pattern() |> Regex.compile("u")

  defp translate_pattern(pattern),
    do: translate_pattern(pattern, false, []) |> IO.iodata_to_binary()

  defp translate_pattern(<<>>, _in_class?, acc), do: Enum.reverse(acc)

  defp translate_pattern(<<"\\", character::utf8, rest::binary>>, in_class?, acc) do
    translate_pattern(rest, in_class?, [<<"\\", character::utf8>> | acc])
  end

  defp translate_pattern(<<"[", rest::binary>>, false, acc),
    do: translate_pattern(rest, true, ["[" | acc])

  defp translate_pattern(<<"]", rest::binary>>, true, acc),
    do: translate_pattern(rest, false, ["]" | acc])

  defp translate_pattern(<<".", rest::binary>>, false, acc),
    do: translate_pattern(rest, false, ["[^\\n\\r\\x{2028}\\x{2029}]" | acc])

  defp translate_pattern(<<"$", rest::binary>>, false, acc),
    do: translate_pattern(rest, false, ["\\z" | acc])

  defp translate_pattern(<<character::utf8, rest::binary>>, in_class?, acc),
    do: translate_pattern(rest, in_class?, [<<character::utf8>> | acc])

  defp validate_properties_schema(schema) do
    case fetch_value(schema, :properties) do
      :error ->
        :ok

      {:ok, properties} when is_map(properties) ->
        if Enum.all?(Map.keys(properties), &(not is_nil(schema_key(&1)))) do
          reduce_schemas(Map.values(properties))
        else
          validation("schema property names must be strings or atoms")
        end

      {:ok, _properties} ->
        validation("schema properties must be a map")
    end
  end

  defp validate_required_schema(schema) do
    case fetch_value(schema, :required) do
      :error ->
        :ok

      {:ok, required} when is_list(required) ->
        if Enum.all?(required, &is_binary/1),
          do: :ok,
          else: validation("schema required must be a list of property names")

      {:ok, _required} ->
        validation("schema required must be a list of property names")
    end
  end

  defp validate_additional_properties_schema(schema) do
    case additional_properties(schema) do
      :error -> :ok
      {:ok, additional} when is_boolean(additional) -> :ok
      {:ok, additional} when is_map(additional) -> validate_schema(additional, :nested)
      {:ok, _additional} -> validation("schema additionalProperties must be a boolean or schema")
    end
  end

  defp validate_child_schema(schema, keyword) do
    case fetch_value(schema, keyword) do
      :error -> :ok
      {:ok, child} when is_map(child) -> validate_schema(child, :nested)
      {:ok, _child} -> validation("schema #{schema_key(keyword)} must be a schema map")
    end
  end

  defp validate_composition_schema(schema, keyword, position) do
    case fetch_value(schema, keyword) do
      :error ->
        :ok

      {:ok, branches} when is_list(branches) and branches != [] ->
        branch_position = if position == :root, do: :object_branch, else: :nested
        reduce_schemas(branches, branch_position)

      {:ok, _branches} ->
        validation("schema #{schema_key(keyword)} must be a non-empty list")
    end
  end

  defp validate_composition_combination(schema) do
    if match?({:ok, _}, fetch_value(schema, :oneOf)) and
         match?({:ok, _}, fetch_value(schema, :anyOf)) do
      {:error, Error.new(:unsupported_capability, "combining schema compositions is unsupported")}
    else
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

  defp validate_value(value, schema, path) do
    with :ok <- validate_type_value(value, schema, path),
         :ok <- validate_enum_value(value, schema, path),
         :ok <- validate_numeric_value(value, schema, path),
         :ok <- validate_string_value(value, schema, path),
         :ok <- validate_array_value(value, schema, path),
         :ok <- validate_object_value(value, schema, path),
         :ok <- validate_any_of_value(value, schema, path),
         :ok <- validate_one_of_value(value, schema, path),
         :ok <- validate_not_value(value, schema, path) do
      :ok
    end
  end

  defp validate_type_value(value, schema, path) do
    case fetch_value(schema, :type) do
      :error ->
        :ok

      {:ok, types} when is_list(types) ->
        if Enum.any?(types, &type_matches?(value, &1)),
          do: :ok,
          else: validation("tool argument has the wrong type", %{path: path, type: types})

      {:ok, type} ->
        if type_matches?(value, type),
          do: :ok,
          else: validation("tool argument has the wrong type", %{path: path, type: type})
    end
  end

  defp type_matches?(value, type) when type in ["object", :object], do: is_map(value)
  defp type_matches?(value, type) when type in ["array", :array], do: is_list(value)
  defp type_matches?(value, type) when type in ["string", :string], do: is_binary(value)
  defp type_matches?(value, type) when type in ["integer", :integer], do: is_integer(value)
  defp type_matches?(value, type) when type in ["number", :number], do: is_number(value)
  defp type_matches?(value, type) when type in ["boolean", :boolean], do: is_boolean(value)
  defp type_matches?(value, type) when type in ["null", :null], do: is_nil(value)

  defp validate_enum_value(value, schema, path) do
    case fetch_value(schema, :enum) do
      :error ->
        :ok

      {:ok, choices} ->
        if Enum.any?(choices, &(&1 == value)),
          do: :ok,
          else: validation("tool argument is not an allowed enum value", %{path: path})
    end
  end

  defp validate_numeric_value(value, schema, path) when is_number(value) do
    with :ok <- validate_minimum(value, schema, path),
         :ok <- validate_maximum(value, schema, path) do
      :ok
    end
  end

  defp validate_numeric_value(_value, _schema, _path), do: :ok

  defp validate_minimum(value, schema, path) do
    case fetch_value(schema, :minimum) do
      {:ok, minimum} when value < minimum ->
        validation("tool argument is below the minimum", %{path: path, minimum: minimum})

      _ ->
        :ok
    end
  end

  defp validate_maximum(value, schema, path) do
    case fetch_value(schema, :maximum) do
      {:ok, maximum} when value > maximum ->
        validation("tool argument is above the maximum", %{path: path, maximum: maximum})

      _ ->
        :ok
    end
  end

  defp validate_string_value(value, schema, path) when is_binary(value) do
    with :ok <- validate_string_length(value, schema, path),
         :ok <- validate_pattern_value(value, schema, path) do
      :ok
    end
  end

  defp validate_string_value(_value, _schema, _path), do: :ok

  defp validate_string_length(value, schema, path) do
    codepoint_count = value |> String.to_charlist() |> length()

    case fetch_value(schema, :minLength) do
      {:ok, minimum} when codepoint_count < minimum ->
        validation("tool argument is shorter than the minimum length", %{
          path: path,
          minLength: minimum
        })

      _ ->
        :ok
    end
  end

  defp validate_pattern_value(value, schema, path) do
    case fetch_value(schema, :pattern) do
      :error ->
        :ok

      {:ok, pattern} ->
        {:ok, regex} = compile_pattern(pattern)
        options = [:report_errors, {:capture, :none}, {:match_limit, @pattern_match_limit}]

        case :re.run(value, regex.re_pattern, options) do
          :match -> :ok
          :nomatch -> validation("tool argument does not match the pattern", %{path: path})
          {:error, reason} -> pattern_execution_failure(path, reason)
        end
    end
  end

  defp validate_array_value(value, schema, path) when is_list(value) do
    with :ok <- validate_array_length(value, schema, path),
         :ok <- validate_array_items(value, schema, path) do
      :ok
    end
  end

  defp validate_array_value(_value, _schema, _path), do: :ok

  defp validate_array_length(value, schema, path) do
    count = length(value)
    minimum = value(schema, :minItems, nil)
    maximum = value(schema, :maxItems, nil)

    cond do
      is_integer(minimum) and count < minimum ->
        validation("tool argument has too few items", %{path: path, minItems: minimum})

      is_integer(maximum) and count > maximum ->
        validation("tool argument has too many items", %{path: path, maxItems: maximum})

      true ->
        :ok
    end
  end

  defp validate_array_items(value, schema, path) do
    case fetch_value(schema, :items) do
      :error ->
        :ok

      {:ok, items} ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
          case validate_value(item, items, "#{path}[#{index}]") do
            :ok -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)
    end
  end

  defp validate_object_value(value, schema, path) when is_map(value) do
    properties = value(schema, :properties, %{})
    required = value(schema, :required, [])

    with :ok <- validate_required(value, required, path),
         :ok <- validate_properties(value, properties, path),
         :ok <- validate_additional(value, properties, schema, path) do
      :ok
    end
  end

  defp validate_object_value(_value, _schema, _path), do: :ok

  defp validate_properties(input, properties, path) do
    Enum.reduce_while(properties, :ok, fn {name, property_schema}, :ok ->
      case fetch_property(input, name) do
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
    additional = additional_properties(schema)

    input
    |> Enum.reject(fn {name, _value} -> MapSet.member?(allowed, schema_key(name)) end)
    |> Enum.reduce_while(:ok, fn {name, additional_value}, :ok ->
      case additional do
        :error ->
          {:cont, :ok}

        {:ok, true} ->
          {:cont, :ok}

        {:ok, false} ->
          {:halt,
           validation("additional tool argument is not allowed", %{path: path, property: name})}

        {:ok, additional_schema} ->
          case validate_value(additional_value, additional_schema, property_path(path, name)) do
            :ok -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  defp validate_any_of_value(value, schema, path) do
    case fetch_value(schema, :anyOf) do
      :error -> :ok
      {:ok, branches} -> validate_branch_matches(value, branches, path, :any)
    end
  end

  defp validate_one_of_value(value, schema, path) do
    case fetch_value(schema, :oneOf) do
      :error -> :ok
      {:ok, branches} -> validate_branch_matches(value, branches, path, :one)
    end
  end

  defp validate_branch_matches(value, branches, path, mode) do
    result =
      Enum.reduce_while(branches, 0, fn branch, matches ->
        case validate_value(value, branch, path) do
          :ok -> {:cont, matches + 1}
          {:error, %Error{class: :validation}} -> {:cont, matches}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)

    case {mode, result} do
      {_mode, {:error, %Error{} = error}} ->
        {:error, error}

      {:any, matches} when matches > 0 ->
        :ok

      {:one, 1} ->
        :ok

      {:any, _matches} ->
        validation("tool argument must match at least one anyOf branch", %{path: path})

      {:one, _matches} ->
        validation("tool argument must match exactly one oneOf branch", %{path: path})
    end
  end

  defp validate_not_value(value, schema, path) do
    case fetch_value(schema, :not) do
      :error ->
        :ok

      {:ok, negated} ->
        case validate_value(value, negated, path) do
          :ok -> validation("tool argument must not match the negated schema", %{path: path})
          {:error, %Error{class: :validation}} -> :ok
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp pattern_execution_failure(path, reason) do
    {:error,
     Error.new(:execution_failure, "schema pattern evaluation failed",
       details: %{path: path, reason: reason}
     )}
  end

  defp json_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item) end)

  defp json_value?(_value), do: false

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

  defp additional_properties(schema) do
    case fetch_value(schema, :additionalProperties) do
      :error -> fetch_value(schema, :additional_properties)
      result -> result
    end
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

  defp schema_key(key) when is_binary(key), do: key
  defp schema_key(key) when is_atom(key), do: Atom.to_string(key)
  defp schema_key(_key), do: nil

  defp validation(message, details \\ %{}),
    do: {:error, Error.new(:validation, message, details: details)}
end
