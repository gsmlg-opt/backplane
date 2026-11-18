defmodule Backplane.McpProtocol.SchemaValidator.Peri do
  @moduledoc """
  Conservative JSON Schema 2020-12 adapter backed by Formata.

  The established preflight and resource bounds still define the admitted
  vocabulary. Formata validates the raw JSON Schema directly, preserving
  JSON number, present-null, and additional-property semantics.
  """

  @behaviour Backplane.McpProtocol.SchemaValidator

  @default_max_depth 64
  @default_max_nodes 1_000

  @annotation_keywords ~w(
    $schema title description default examples deprecated readOnly writeOnly
  )

  @assertion_keywords ~w(
    type properties required items additionalProperties
    enum const
    minLength maxLength pattern format
    minimum maximum exclusiveMinimum exclusiveMaximum
  )

  @assertion_keyword_order ~w(
    enum const properties required items additionalProperties
    minLength maxLength pattern format
    minimum maximum exclusiveMinimum exclusiveMaximum
  )

  @json_types ~w(object array string integer number boolean null)

  defmodule Compiled do
    @moduledoc false
    @enforce_keys [:json_schema, :schema]
    defstruct [:json_schema, :schema]
  end

  @impl true
  def compile(schema, opts) when is_map(schema) and is_list(opts) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_nodes = Keyword.get(opts, :max_nodes, @default_max_nodes)

    with {:ok, _remaining} <- bound_nodes(schema, max_nodes),
         :ok <- preflight(schema, max_depth, []),
         {:ok, compiled} <- Formata.Schema.json_schema(schema, dialect: :draft2020_12) do
      {:ok, %Compiled{json_schema: schema, schema: compiled}}
    end
  end

  def compile(_schema, _opts), do: {:error, :schema_must_be_a_map}

  @impl true
  def validate(%Compiled{schema: schema}, value, _opts), do: Formata.validate(value, schema)

  def validate(_compiled, _value, _opts), do: {:error, [:invalid_compiled_schema]}

  defp preflight(_schema, depth, _path) when depth < 0, do: {:unsupported, :max_depth_exceeded}

  defp preflight(schema, depth, path) when is_map(schema) do
    with :ok <- validate_keyword_shapes(schema),
         :ok <- validate_assertion_combinations(schema),
         :ok <- validate_keyword_compatibility(schema) do
      Enum.reduce_while(schema, :ok, fn {keyword, value}, :ok ->
        cond do
          keyword in @annotation_keywords ->
            {:cont, :ok}

          keyword in @assertion_keywords ->
            case preflight_keyword(keyword, value, depth, path) do
              :ok -> {:cont, :ok}
              other -> {:halt, other}
            end

          true ->
            {:halt, {:unsupported, {:unsupported_keyword, Enum.reverse([keyword | path])}}}
        end
      end)
    end
  end

  defp preflight(_schema, _depth, path),
    do: {:unsupported, {:schema_must_be_a_map, Enum.reverse(path)}}

  defp preflight_keyword("properties", properties, depth, path) when is_map(properties) do
    Enum.reduce_while(properties, :ok, fn {name, property_schema}, :ok ->
      case preflight(property_schema, depth - 1, [name, "properties" | path]) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  defp preflight_keyword("items", items, depth, path) when is_map(items),
    do: preflight(items, depth - 1, ["items" | path])

  defp preflight_keyword("additionalProperties", schema, depth, path) when is_map(schema),
    do: preflight(schema, depth - 1, ["additionalProperties" | path])

  defp preflight_keyword("pattern", pattern, _depth, path) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, _regex} -> {:unsupported, {:unsupported_keyword, Enum.reverse(["pattern" | path])}}
      {:error, _reason} -> {:error, {:invalid_pattern, pattern}}
    end
  end

  defp preflight_keyword("format", format, _depth, _path),
    do: {:unsupported, {:unsupported_format, format}}

  defp preflight_keyword(keyword, _value, _depth, path)
       when keyword in ["minLength", "maxLength"] do
    {:unsupported, {:unsupported_keyword, Enum.reverse([keyword | path])}}
  end

  defp preflight_keyword(keyword, value, _depth, _path)
       when keyword in ["properties", "items", "additionalProperties"] do
    {:unsupported, {:unsupported_keyword_value, keyword, value}}
  end

  defp preflight_keyword(_keyword, _value, _depth, _path), do: :ok

  defp validate_keyword_shapes(schema) do
    with :ok <- validate_type_shape(Map.fetch(schema, "type")),
         :ok <- validate_required_shape(Map.fetch(schema, "required")),
         :ok <- validate_enum_shape(Map.fetch(schema, "enum")),
         :ok <- validate_pattern_shape(Map.fetch(schema, "pattern")),
         :ok <- validate_nonnegative_integer_shape(schema, "minLength"),
         :ok <- validate_nonnegative_integer_shape(schema, "maxLength") do
      validate_number_bound_shapes(schema)
    end
  end

  defp validate_type_shape(:error), do: :ok
  defp validate_type_shape({:ok, type}) when type in @json_types, do: :ok

  defp validate_type_shape({:ok, types}) when is_list(types) do
    if types != [] and Enum.all?(types, &(&1 in @json_types)) and Enum.uniq(types) == types,
      do: :ok,
      else: {:error, {:invalid_keyword_value, "type", types}}
  end

  defp validate_type_shape({:ok, type}), do: {:error, {:invalid_keyword_value, "type", type}}

  defp validate_required_shape(:error), do: :ok

  defp validate_required_shape({:ok, required}) when is_list(required) do
    if Enum.all?(required, &is_binary/1) and Enum.uniq(required) == required,
      do: :ok,
      else: {:error, {:invalid_keyword_value, "required", required}}
  end

  defp validate_required_shape({:ok, required}),
    do: {:error, {:invalid_keyword_value, "required", required}}

  defp validate_enum_shape(:error), do: :ok

  defp validate_enum_shape({:ok, values}) when is_list(values) do
    if values != [] and Enum.uniq(values) == values,
      do: :ok,
      else: {:error, {:invalid_keyword_value, "enum", values}}
  end

  defp validate_enum_shape({:ok, values}), do: {:error, {:invalid_keyword_value, "enum", values}}

  defp validate_pattern_shape(:error), do: :ok
  defp validate_pattern_shape({:ok, pattern}) when is_binary(pattern), do: :ok

  defp validate_pattern_shape({:ok, pattern}),
    do: {:error, {:invalid_keyword_value, "pattern", pattern}}

  defp validate_nonnegative_integer_shape(schema, keyword) do
    case Map.fetch(schema, keyword) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, value} -> {:error, {:invalid_keyword_value, keyword, value}}
    end
  end

  defp validate_number_bound_shapes(schema) do
    Enum.reduce_while(~w(minimum maximum exclusiveMinimum exclusiveMaximum), :ok, fn keyword,
                                                                                     :ok ->
      case Map.fetch(schema, keyword) do
        :error -> {:cont, :ok}
        {:ok, value} when is_number(value) -> {:cont, :ok}
        {:ok, value} -> {:halt, {:error, {:invalid_keyword_value, keyword, value}}}
      end
    end)
  end

  defp validate_assertion_combinations(schema) do
    discriminator? = Map.has_key?(schema, "enum") or Map.has_key?(schema, "const")
    assertion_keys = Enum.filter(@assertion_keyword_order, &Map.has_key?(schema, &1))
    other_assertion? = Enum.any?(assertion_keys, &(&1 not in ["enum", "const"]))

    if discriminator? and other_assertion?,
      do: {:unsupported, {:unsupported_assertion_combination, assertion_keys}},
      else: :ok
  end

  defp validate_keyword_compatibility(schema) do
    requirements = [
      {~w(properties required additionalProperties), "object"},
      {["items"], "array"},
      {~w(minLength maxLength pattern format), "string"},
      {~w(minimum maximum exclusiveMinimum exclusiveMaximum), ["integer", "number"]}
    ]

    Enum.reduce_while(requirements, :ok, fn {keywords, compatible_types}, :ok ->
      case Enum.find(keywords, &Map.has_key?(schema, &1)) do
        nil ->
          {:cont, :ok}

        keyword ->
          if compatible_type?(Map.get(schema, "type"), compatible_types) do
            {:cont, :ok}
          else
            {:halt, {:unsupported, {:missing_compatible_type, keyword}}}
          end
      end
    end)
  end

  defp compatible_type?(type, compatible_types) when is_list(compatible_types),
    do: type in compatible_types

  defp compatible_type?(type, compatible_type), do: type == compatible_type

  defp bound_nodes(_schema, remaining) when remaining <= 0,
    do: {:unsupported, :max_nodes_exceeded}

  defp bound_nodes(schema, remaining) when is_map(schema) do
    nested_schemas = nested_schemas(schema)

    Enum.reduce_while(nested_schemas, {:ok, remaining - 1}, fn nested, {:ok, left} ->
      case bound_nodes(nested, left) do
        {:ok, next_left} -> {:cont, {:ok, next_left}}
        other -> {:halt, other}
      end
    end)
  end

  defp bound_nodes(_schema, remaining), do: {:ok, remaining - 1}

  defp nested_schemas(schema) do
    properties =
      case schema do
        %{"properties" => properties} when is_map(properties) -> Map.values(properties)
        _ -> []
      end

    items =
      case schema do
        %{"items" => items} when is_map(items) -> [items]
        _ -> []
      end

    additional_properties =
      case schema do
        %{"additionalProperties" => additional} when is_map(additional) -> [additional]
        _ -> []
      end

    properties ++ items ++ additional_properties
  end
end
