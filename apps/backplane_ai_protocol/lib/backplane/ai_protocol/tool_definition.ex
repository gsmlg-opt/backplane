defmodule Backplane.AiProtocol.ToolDefinition do
  @moduledoc """
  Provider-neutral tool declaration.

  A definition only describes and validates a tool. It never grants authorization to execute it.
  """

  alias Backplane.AiProtocol.Error

  @enforce_keys [:name]
  defstruct [:name, :description, :input_schema, extensions: %{}]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          input_schema: map() | nil,
          extensions: map()
        }

  @keys [:name, :description, :input_schema, :extensions]

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs, opts \\ [])
  def new(%__MODULE__{} = tool, opts), do: tool |> Map.from_struct() |> new(opts)

  def new(attrs, opts) when is_map(attrs) do
    limits = Keyword.get(opts, :limits, %{})

    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, name} <- tool_name(Map.get(attrs, :name)),
         :ok <- optional_string(attrs, :description, limits),
         :ok <- schema(attrs[:input_schema], limits),
         :ok <- extensions(attrs[:extensions], limits) do
      {:ok,
       %__MODULE__{
         name: name,
         description: attrs[:description],
         input_schema: attrs[:input_schema],
         extensions: attrs[:extensions] || %{}
       }}
    end
  end

  @doc false
  def keys, do: @keys

  defp tool_name(value) when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.match?(value, ~r/^[a-zA-Z0-9_.-]+$/) do
      {:ok, value}
    else
      {:error, Error.invalid!("Tool name contains invalid characters")}
    end
  end

  defp tool_name(_value), do: {:error, Error.invalid!("Tool name must be a bounded string")}

  defp optional_string(attrs, key, limits) do
    case Map.get(attrs, key) do
      nil -> :ok
      value when is_binary(value) -> Backplane.AiProtocol.Validation.term(value, limits)
      _ -> {:error, Error.invalid!("Tool #{key} must be a string")}
    end
  end

  defp schema(nil, _limits), do: :ok

  defp schema(value, limits) when is_map(value),
    do: Backplane.AiProtocol.Validation.term(value, limits)

  defp schema(_value, _limits), do: {:error, Error.invalid!("Tool input schema must be a map")}

  defp extensions(value, limits), do: extension_map(value, limits)

  defp extension_map(nil, _limits), do: :ok

  defp extension_map(extensions, limits) do
    Enum.reduce_while(extensions, :ok, fn
      {name, value}, :ok ->
        case Backplane.AiProtocol.Validation.bounded_extension(name, value, limits) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, Error.invalid!("Tool extensions must be a string-keyed map")}}
    end)
  end
end
