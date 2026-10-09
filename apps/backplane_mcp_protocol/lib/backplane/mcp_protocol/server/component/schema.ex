defmodule Backplane.McpProtocol.Server.Component.Schema do
  @moduledoc false

  alias Backplane.McpProtocol.SchemaValidator.Peri, as: PeriValidator
  alias Backplane.McpProtocol.Server.Component

  @opaque raw_schema :: {:json_schema, map()}
  @type schema :: map() | list() | raw_schema()
  @type field_type :: atom() | tuple()
  @type json_schema :: map()
  @type prompt_argument :: map()
  @type validator :: (term() -> {:ok, term()} | {:error, term()})

  @doc """
  Marks a server-authored map as a raw JSON Schema wire document.

  Untagged maps and lists remain the existing Peri DSL.
  """
  @spec raw(map()) :: raw_schema()
  def raw(schema) when is_map(schema), do: {:json_schema, schema}

  @doc false
  @spec raw?(term()) :: boolean()
  def raw?({:json_schema, schema}) when is_map(schema), do: true
  def raw?(_schema), do: false

  @spec to_json_schema(schema() | nil) :: json_schema()
  def to_json_schema(nil), do: %{"type" => "object"}
  def to_json_schema({:json_schema, schema}) when is_map(schema), do: schema

  def to_json_schema(schema) when is_list(schema) do
    schema |> Map.new() |> to_json_schema()
  end

  def to_json_schema(schema) when is_map(schema) do
    # Defaults live in `{type, {:default, v}}` after `__build_field__/2`. Strip
    # them from JSON Schema output so consumer schemas don't surface internal
    # defaults — prompt docs and validation still use them.
    schema
    |> Component.__expand_user_input__()
    |> Peri.to_json_schema(exclude_meta_keys: [:default])
  end

  @spec to_prompt_arguments(schema() | nil) :: [prompt_argument()]
  def to_prompt_arguments(nil), do: []

  def to_prompt_arguments(schema) when is_list(schema) do
    schema |> Map.new() |> to_prompt_arguments()
  end

  def to_prompt_arguments(schema) when is_map(schema) do
    expanded = Component.__expand_user_input__(schema)

    Enum.map(expanded, fn {key, type} ->
      %{
        "name" => to_string(key),
        "description" => describe_type(type),
        "required" => required?(type)
      }
    end)
  end

  @spec format_errors(map() | binary() | [map() | binary()]) :: binary()
  def format_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", &format_error/1)
  end

  def format_errors(error), do: format_errors([error])

  defp format_error(%Peri.Error{errors: [_ | _] = errors}), do: format_errors(errors)

  defp format_error(%{path: path, message: message}) do
    path_str = Enum.join(path || [], ".")
    if path_str == "", do: message, else: "#{path_str}: #{message}"
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error, pretty: true)

  defp required?({:required, _}), do: true
  defp required?({:meta, type, _}), do: required?(type)
  defp required?(_), do: false

  defp describe_type({:required, {:meta, type, opts}}) do
    Keyword.get(opts, :description) || "Required " <> describe_base_type(type)
  end

  defp describe_type({:required, type}), do: "Required " <> describe_base_type(type)

  defp describe_type({:meta, type, opts}) do
    Keyword.get(opts, :description) || describe_type(type)
  end

  defp describe_type({type, {:default, default}}) do
    "Optional " <> describe_base_type(type) <> " (default: #{to_string(default)})"
  end

  defp describe_type(type), do: "Optional " <> describe_base_type(type)

  defp describe_base_type(:string), do: "string parameter"
  defp describe_base_type(:integer), do: "integer parameter"
  defp describe_base_type(:float), do: "number parameter"
  defp describe_base_type(:boolean), do: "boolean parameter"

  defp describe_base_type({:enum, values}), do: "one of: #{inspect(values, pretty: true)}"
  defp describe_base_type({:enum, values, _opts}), do: "one of: #{inspect(values, pretty: true)}"

  defp describe_base_type({:list, {type, _}}), do: "array of #{describe_base_type(type)} elements parameter"
  defp describe_base_type({:list, type}), do: "array of #{describe_base_type(type)} elements parameter"
  defp describe_base_type({:list, type, _opts}), do: "array of #{describe_base_type(type)} elements parameter"

  defp describe_base_type({:map, _}), do: "object parameter"
  defp describe_base_type({:meta, type, _}), do: describe_base_type(type)
  defp describe_base_type({type, _}), do: "#{to_string(type)} parameter"
  defp describe_base_type(schema) when is_map(schema), do: "nested object"
  defp describe_base_type(_), do: "parameter"

  @doc """
  Builds a validator, with Peri DSL errors normalized for custom-field composition.

  Use `{:custom, validator(inner_schema)}` to delegate to another Peri schema.
  Error lists have valid root paths so Peri can prefix enclosing field names.
  """
  @spec validator(schema() | Peri.schema()) :: validator()
  def validator({:json_schema, _schema} = schema) do
    case compile_validator(schema) do
      {:ok, validator} -> validator
      {:unsupported, _reason} -> &passthrough/1
      {:error, _reason} -> &passthrough/1
    end
  end

  def validator(schema) when is_list(schema) do
    schema |> Map.new() |> validator()
  end

  def validator(schema) do
    peri_schema = Component.__clean_schema_for_peri__(schema)

    fn params ->
      prepared = peri_schema |> expand_additional_keys(params) |> prepare_composition()
      normalize_peri_result(Peri.validate(prepared, params))
    end
  end

  defp prepare_composition(schema) do
    Peri.walk(schema, fn
      {:custom, callback} ->
        {:cont, {:custom, fn value -> normalize_peri_result(call_validator(callback, value)) end}}

      {:list, {:custom, _} = item_type} ->
        {:cont, {:custom, list_validator(item_type, [])}}

      {:list, {:custom, _} = item_type, opts} when is_list(opts) ->
        {:cont, {:custom, list_validator(item_type, opts)}}

      {:list, item_type, opts} when is_list(opts) ->
        {:cont, {:list, prepare_composition(item_type), opts}}

      {type, {modifier, callback}} when modifier in [:default, :transform, :encode] ->
        {:cont, {prepare_composition(type), {modifier, callback}}}

      {:schema, fields, opts} when is_list(opts) ->
        {:cont, {:schema, prepare_composition(fields), opts}}

      other ->
        {:cont, other}
    end)
  end

  defp call_validator(callback, value) when is_function(callback, 1), do: callback.(value)
  defp call_validator({mod, fun}, value), do: apply(mod, fun, [value])
  defp call_validator({mod, fun, args}, value), do: apply(mod, fun, [value | args])

  defp expand_additional_keys({:schema, fields, {:additional_keys, value_type}}, value)
       when is_map(fields) and is_map(value) do
    # Concrete fields retain dynamic keys without resetting Peri's outer root context.
    declared_keys = fields |> Map.keys() |> Enum.flat_map(&[&1, to_string(&1)])
    extra_fields = value |> Map.drop(declared_keys) |> Map.new(fn {key, _} -> {key, value_type} end)
    expand_additional_keys(Map.merge(fields, extra_fields), value)
  end

  defp expand_additional_keys(fields, value) when is_map(fields) and is_map(value) do
    Map.new(fields, fn {key, type} ->
      field_value = Map.get(value, key, Map.get(value, to_string(key)))
      {key, expand_additional_keys(type, field_value)}
    end)
  end

  defp expand_additional_keys({:required, type}, value), do: {:required, expand_additional_keys(type, value)}

  defp expand_additional_keys({:required, type, opts}, value), do: {:required, expand_additional_keys(type, value), opts}

  defp expand_additional_keys({:meta, type, opts}, value), do: {:meta, expand_additional_keys(type, value), opts}

  defp expand_additional_keys({:schema, fields}, value), do: {:schema, expand_additional_keys(fields, value)}

  defp expand_additional_keys({:schema, fields, opts}, value) when is_list(opts),
    do: {:schema, expand_additional_keys(fields, value), opts}

  defp expand_additional_keys({type, {modifier, callback}}, value) when modifier in [:default, :transform, :encode],
    do: {expand_additional_keys(type, value), {modifier, callback}}

  defp expand_additional_keys(schema, _value), do: schema

  defp list_validator(item_type, opts) do
    item_validator = validator(item_type)

    fn value ->
      with_result =
        with {:ok, values} <- Peri.validate({:list, :any, opts}, value) do
          values
          |> Enum.with_index()
          |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
            case item_validator.(item) do
              {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
              {:error, errors} -> {:halt, {:error, Enum.map(errors, &Peri.Error.update_error_paths(&1, [index]))}}
            end
          end)
          |> then(fn
            {:ok, values} -> {:ok, Enum.reverse(values)}
            error -> error
          end)
        end

      normalize_peri_result(with_result)
    end
  end

  defp normalize_peri_result({:error, errors}), do: {:error, Enum.map(List.wrap(errors), &normalize_peri_error/1)}
  defp normalize_peri_result(result), do: result

  defp normalize_peri_error(%Peri.Error{} = error) do
    nested =
      if is_list(error.errors),
        do: Enum.map(error.errors, &normalize_peri_error/1),
        else: error.errors

    %{error | path: error.path || [], errors: nested}
  end

  defp normalize_peri_error(error), do: error

  @doc false
  @spec compile_validator(schema(), keyword()) ::
          {:ok, validator()} | {:unsupported, term()} | {:error, term()}
  def compile_validator(schema, opts \\ [])

  def compile_validator({:json_schema, schema}, opts) when is_map(schema) do
    case PeriValidator.compile(schema, opts) do
      {:ok, compiled} ->
        {:ok,
         fn value ->
           case PeriValidator.validate(compiled, value, opts) do
             :ok -> {:ok, value}
             {:error, errors} -> {:error, errors}
           end
         end}

      other ->
        other
    end
  end

  def compile_validator(schema, _opts), do: {:ok, validator(schema)}

  defp passthrough(value), do: {:ok, value}
end
