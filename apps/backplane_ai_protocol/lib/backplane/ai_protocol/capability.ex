defmodule Backplane.AiProtocol.Capability do
  @moduledoc """
  Tri-state capability with explicit provenance and staleness.

  A missing observation is `:unknown`, never implicitly `:unsupported`.
  """

  alias Backplane.AiProtocol.Error

  @enforce_keys [:name, :state]
  defstruct [
    :name,
    :state,
    :source,
    :observed_at,
    :revision,
    :stale_after,
    :confidence,
    details: %{}
  ]

  @type state :: :supported | :unsupported | :unknown

  @type t :: %__MODULE__{
          name: String.t(),
          state: state(),
          source: String.t() | nil,
          observed_at: term() | nil,
          revision: term() | nil,
          stale_after: term() | nil,
          confidence: number() | nil,
          details: map()
        }

  @keys [:name, :state, :source, :observed_at, :revision, :stale_after, :confidence, :details]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, name} <- bounded_string(attrs, :name),
         {:ok, state} <- state(Map.get(attrs, :state)),
         :ok <- optional_string(attrs, :source),
         :ok <- Backplane.AiProtocol.Validation.bounded_map(attrs[:details] || %{}),
         :ok <- confidence(attrs[:confidence]) do
      capability = struct(__MODULE__, Map.take(attrs, @keys))

      {:ok, %{capability | name: name, state: state}}
    end
  end

  @doc false
  def keys, do: @keys

  defp bounded_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.invalid!("Capability #{key} must be a non-empty string")}
    end
  end

  defp state(value) when value in [:supported, :unsupported, :unknown], do: {:ok, value}

  defp state(_value),
    do: {:error, Error.invalid!("Capability state must be supported, unsupported, or unknown")}

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        :ok

      value when is_binary(value) ->
        case Backplane.AiProtocol.Validation.term(value) do
          {:ok, _bytes} -> :ok
          error -> error
        end

      _ ->
        {:error, Error.invalid!("Capability #{key} must be a string")}
    end
  end

  defp confidence(nil), do: :ok
  defp confidence(value) when is_number(value) and value >= 0 and value <= 1, do: :ok

  defp confidence(_value),
    do: {:error, Error.invalid!("Capability confidence must be between 0 and 1")}
end
