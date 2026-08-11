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

  @spec format_errors([map()] | [binary()]) :: binary()
  def format_errors(errors) when is_list(errors) do
    Enum.map_join(errors, "; ", &format_error/1)
  end

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

  @spec validator(schema()) :: validator()
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
    fn params -> Peri.validate(peri_schema, params) end
  end

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
