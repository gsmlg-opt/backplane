defmodule Backplane.AiProtocol.Usage do
  @moduledoc """
  Provider usage counters with explicit source, mode, and observation completeness.
  """

  alias Backplane.AiProtocol.Error

  @enforce_keys [:mode, :status, :source]
  defstruct [
    :mode,
    :status,
    :source,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :native_total,
    :attempt_id,
    extensions: %{}
  ]

  @type mode :: :snapshot | :delta
  @type status :: :complete | :partial | :unknown

  @type t :: %__MODULE__{
          mode: mode(),
          status: status(),
          source: String.t(),
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          native_total: non_neg_integer() | nil,
          attempt_id: String.t() | nil,
          extensions: map()
        }

  @keys [
    :mode,
    :status,
    :source,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :native_total,
    :attempt_id,
    :extensions
  ]

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, _mode} <- mode(Map.get(attrs, :mode)),
         {:ok, _status} <- status(Map.get(attrs, :status)),
         {:ok, _source} <- source(Map.get(attrs, :source)),
         :ok <- counters(attrs),
         :ok <- extensions(attrs[:extensions]) do
      {:ok, %{struct(__MODULE__, Map.take(attrs, @keys)) | extensions: attrs[:extensions] || %{}}}
    end
  end

  @doc false
  def keys, do: @keys

  defp mode(value) when value in [:snapshot, :delta], do: {:ok, value}
  defp mode(_value), do: {:error, Error.invalid!("Usage mode must be snapshot or delta")}

  defp status(value) when value in [:complete, :partial, :unknown], do: {:ok, value}

  defp status(_value),
    do: {:error, Error.invalid!("Usage status must be complete, partial, or unknown")}

  defp source(value) when is_binary(value) and value != "", do: {:ok, value}
  defp source(_value), do: {:error, Error.invalid!("Usage source must be a non-empty string")}

  @counter_keys [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :native_total
  ]

  defp counters(attrs) do
    Enum.reduce_while(@counter_keys, :ok, fn key, :ok ->
      case Map.get(attrs, key) do
        nil -> {:cont, :ok}
        value when is_integer(value) and value >= 0 -> {:cont, :ok}
        _ -> {:halt, {:error, Error.invalid!("Usage #{key} must be a non-negative integer")}}
      end
    end)
  end

  defp extensions(nil), do: :ok

  defp extensions(value) when is_map(value),
    do: Backplane.AiProtocol.Validation.bounded_map(value)

  defp extensions(_value), do: {:error, Error.invalid!("Usage extensions must be a map")}
end
