defmodule Backplane.McpProtocol.Client.JSONSchemaConverter do
  @moduledoc false

  alias Backplane.McpProtocol.SchemaValidator.Peri, as: PeriValidator

  @type json_schema :: map()
  @type peri_schema :: Peri.schema_def()
  @type validator :: (term() -> {:ok, term()} | {:error, term()})
  @type legacy_validator :: (term() -> {:ok, term()} | {:error, list(Peri.Error.t())})

  @doc """
  Converts a JSON Schema (Draft 7) into a Peri schema.
  """
  @spec to_peri(json_schema()) :: {:ok, peri_schema()} | {:error, list(Peri.Error.t())}
  defdelegate to_peri(json_schema), to: Peri, as: :from_json_schema

  @doc """
  Creates a validator function from a JSON Schema.

  Returns a function that takes a value and returns either
  `{:ok, value}` or `{:error, errors}`.
  """
  @spec validator(json_schema()) :: {:ok, legacy_validator()} | {:error, list(Peri.Error.t())}
  def validator(json_schema) do
    with {:ok, peri_schema} <- to_peri(json_schema) do
      {:ok, fn value -> Peri.validate(peri_schema, value) end}
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
