defmodule Backplane.AiProtocol.ToolCall do
  @moduledoc """
  Canonical tool invocation identity and argument provenance.

  `raw_arguments` preserves provider bytes or structured input. `validated_arguments` is filled
  only by a separately validated path; it must not be treated as execution authorization.
  """

  alias Backplane.AiProtocol.Error

  @enforce_keys [:id, :name, :raw_arguments]
  defstruct [:id, :native_id, :name, :raw_arguments, :validated_arguments]

  @type structured_arguments :: map()

  @type raw_arguments :: {:json, binary()} | {:structured, structured_arguments()}

  @type t :: %__MODULE__{
          id: String.t(),
          native_id: String.t() | nil,
          name: String.t(),
          raw_arguments: raw_arguments(),
          validated_arguments: term() | nil
        }

  @keys [:id, :native_id, :name, :raw_arguments, :validated_arguments]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = call), do: call |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, id} <- identity(attrs, :id),
         {:ok, name} <- tool_name(Map.get(attrs, :name)),
         {:ok, raw_arguments} <- raw_arguments(Map.get(attrs, :raw_arguments)),
         :ok <- optional_identity(attrs),
         :ok <- validated_arguments(attrs[:validated_arguments]) do
      {:ok,
       %__MODULE__{
         id: id,
         native_id: attrs[:native_id],
         name: name,
         raw_arguments: raw_arguments,
         validated_arguments: attrs[:validated_arguments]
       }}
    end
  end

  @spec put_validated_arguments(t(), term()) :: {:ok, t()} | {:error, Error.t()}
  def put_validated_arguments(%__MODULE__{} = call, value) do
    with :ok <- Backplane.AiProtocol.Validation.term(value) do
      {:ok, %{call | validated_arguments: value}}
    end
  end

  @doc false
  def keys, do: @keys

  defp identity(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" and byte_size(value) <= 256 -> {:ok, value}
      _ -> {:error, Error.invalid!("Tool call #{key} must be a non-empty bounded string")}
    end
  end

  defp optional_identity(attrs) do
    case attrs[:native_id] do
      nil -> :ok
      value when is_binary(value) and byte_size(value) <= 256 -> :ok
      _ -> {:error, Error.invalid!("Tool call native_id must be a bounded string")}
    end
  end

  defp tool_name(value) when is_binary(value) and value != "" and byte_size(value) <= 256 do
    if String.match?(value, ~r/^[a-zA-Z0-9_.-]+$/) do
      {:ok, value}
    else
      {:error, Error.invalid!("Tool call name contains invalid characters")}
    end
  end

  defp tool_name(_value), do: {:error, Error.invalid!("Tool call name must be a bounded string")}

  defp raw_arguments({:json, bytes}) when is_binary(bytes) do
    with {:ok, _bytes} <- non_empty_arguments(bytes),
         :ok <- Backplane.AiProtocol.Validation.term(bytes) do
      {:ok, {:json, bytes}}
    end
  end

  defp raw_arguments({:structured, value}) do
    with {:ok, _bytes} <- structured_arguments(value),
         :ok <- Backplane.AiProtocol.Validation.term(value) do
      {:ok, {:structured, value}}
    end
  end

  defp structured_arguments(value) when is_map(value) do
    case Backplane.AiProtocol.Validation.term(value) do
      :ok -> {:ok, 0}
      error -> error
    end
  end

  defp structured_arguments(_value),
    do: {:error, Error.invalid!("Structured tool call arguments must be a map")}

  defp non_empty_arguments(""),
    do: {:error, Error.invalid!("Tool call JSON arguments cannot be empty")}

  defp non_empty_arguments(_value), do: {:ok, 0}

  defp validated_arguments(nil), do: :ok

  defp validated_arguments(value) do
    Backplane.AiProtocol.Validation.term(value)
  end
end
