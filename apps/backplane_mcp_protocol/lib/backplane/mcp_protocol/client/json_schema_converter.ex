defmodule Backplane.McpProtocol.Client.JSONSchemaConverter do
  @moduledoc false

  alias Backplane.McpProtocol.SchemaValidator.Peri, as: PeriValidator

  @type json_schema :: map()
  @type peri_schema :: Formata.NativeSchema.schema_def()
  @type validator :: (term() -> {:ok, term()} | {:error, term()})
  @type legacy_validator :: (term() -> {:ok, term()} | {:error, list(Formata.Error.t())})

  @doc """
  Imports the supported Draft 7 subset into a native schema definition.

  Constraints that cannot be represented faithfully return structured errors.
  Use `validator/1` to validate a JSON Schema document directly.
  """
  @spec to_peri(json_schema()) :: {:ok, peri_schema()} | {:error, list(Formata.Error.t())}
  defdelegate to_peri(json_schema), to: Formata.Schema.Native, as: :from_json_schema

  @doc """
  Creates a validator function from a JSON Schema.

  Returns a function that takes a value and returns either
  `{:ok, value}` or `{:error, errors}`.
  """
  @spec validator(json_schema()) :: {:ok, legacy_validator()} | {:error, list(Formata.Error.t())}
  def validator(json_schema) do
    with {:ok, schema} <-
           Formata.Schema.json_schema(json_schema, dialect: :draft7, format_assertion: true) do
      {:ok,
       fn value ->
         case Formata.validate(value, schema) do
           :ok -> {:ok, value}
           {:error, errors} -> {:error, errors}
         end
       end}
    end
  end

  @doc """
  Compiles the proven JSON Schema 2020-12 subset without changing the raw
  schema document.
  """
  @spec compile_2020_12(json_schema(), keyword()) ::
          {:ok, term()} | {:unsupported, term()} | {:error, term()}
  def compile_2020_12(json_schema, opts \\ []) do
    PeriValidator.compile(json_schema, opts)
  end

  @doc """
  Creates a value-preserving validator for the supported 2020-12 subset.
  """
  @spec validator_2020_12(json_schema(), keyword()) ::
          {:ok, validator()} | {:unsupported, term()} | {:error, term()}
  def validator_2020_12(json_schema, opts \\ []) do
    case compile_2020_12(json_schema, opts) do
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
end
