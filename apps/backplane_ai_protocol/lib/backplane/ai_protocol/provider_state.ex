defmodule Backplane.AiProtocol.ProviderState do
  @moduledoc """
  Origin-bound, opaque provider state.

  Payloads are not interpreted or converted to display text. Affinity is explicit and public;
  internal credential identifiers are forbidden here.
  """

  alias Backplane.AiProtocol.{Affinity, Error}

  @enforce_keys [:source_profile, :source_protocol, :kind, :affinity]
  defstruct [
    :source_profile,
    :source_protocol,
    :kind,
    :affinity,
    :payload,
    :payload_reference,
    constraints: %{},
    extensions: %{}
  ]

  @type t :: %__MODULE__{
          source_profile: String.t(),
          source_protocol: String.t(),
          kind: String.t(),
          affinity: Affinity.t(),
          payload: term() | nil,
          payload_reference: term() | nil,
          constraints: map(),
          extensions: map()
        }

  @keys [
    :source_profile,
    :source_protocol,
    :kind,
    :affinity,
    :payload,
    :payload_reference,
    :constraints,
    :extensions
  ]

  @spec new(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs, opts \\ [])
  def new(%__MODULE__{} = state, opts), do: state |> Map.from_struct() |> new(opts)

  def new(attrs, opts) when is_map(attrs) do
    limits = Keyword.get(opts, :limits, %{})

    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, source_profile} <- bounded_string(attrs, :source_profile),
         {:ok, source_protocol} <- bounded_string(attrs, :source_protocol),
         {:ok, kind} <- bounded_string(attrs, :kind),
         {:ok, affinity} <- affinity(Map.get(attrs, :affinity)),
         :ok <- payload(attrs, limits),
         :ok <- constraints(attrs[:constraints], limits),
         :ok <- extensions(attrs[:extensions], limits) do
      {:ok,
       %__MODULE__{
         source_profile: source_profile,
         source_protocol: source_protocol,
         kind: kind,
         affinity: affinity,
         payload: attrs[:payload],
         payload_reference: attrs[:payload_reference],
         constraints: attrs[:constraints] || %{},
         extensions: attrs[:extensions] || %{}
       }}
    end
  end

  @doc false
  def keys, do: @keys

  defp bounded_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.invalid!("Provider state #{key} must be a non-empty string")}
    end
  end

  defp affinity(%Affinity{} = affinity), do: affinity |> Map.from_struct() |> Affinity.new()

  defp affinity(attrs) when is_map(attrs) do
    case Affinity.new(attrs) do
      {:ok, affinity} ->
        {:ok, affinity}

      {:error, %Error{message: message}} ->
        {:error, Error.invalid!("Provider state affinity: " <> message)}
    end
  end

  defp affinity(_value), do: {:error, Error.invalid!("Provider state affinity is required")}

  defp payload(attrs, limits) do
    case {attrs[:payload], attrs[:payload_reference]} do
      {nil, nil} ->
        {:error, Error.invalid!("Provider state requires payload or payload_reference")}

      {payload, reference} when payload != nil and reference != nil ->
        {:error,
         Error.invalid!("Provider state cannot contain both payload and payload_reference")}

      {payload, reference} ->
        with :ok <- validate_payload(payload, limits),
             :ok <- validate_payload(reference, limits) do
          :ok
        end
    end
  end

  defp validate_payload(nil, _limits), do: :ok

  defp validate_payload(value, limits) when is_binary(value) do
    max = Map.get(limits, :max_bytes, Backplane.AiProtocol.Validation.default_limits().max_bytes)

    if byte_size(value) <= max,
      do: :ok,
      else: {:error, Error.invalid!("Opaque provider state exceeds byte limit")}
  end

  defp validate_payload(value, limits), do: Backplane.AiProtocol.Validation.term(value, limits)

  defp constraints(value, limits), do: bounded_map(value, :constraints, limits)
  defp extensions(value, limits), do: bounded_map(value, :extensions, limits)

  defp bounded_map(nil, _key, _limits), do: :ok

  defp bounded_map(value, _key, limits) when is_map(value),
    do: Backplane.AiProtocol.Validation.bounded_map(value, limits)

  defp bounded_map(_value, key, _limits),
    do: {:error, Error.invalid!("Provider state #{key} must be a map")}
end
