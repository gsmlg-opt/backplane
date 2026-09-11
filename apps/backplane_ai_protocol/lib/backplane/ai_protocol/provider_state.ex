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

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = state), do: {:ok, state}

  def new(attrs) when is_map(attrs) do
    with :ok <- Backplane.AiProtocol.Validation.reject_unknown(attrs, @keys),
         {:ok, source_profile} <- bounded_string(attrs, :source_profile),
         {:ok, source_protocol} <- bounded_string(attrs, :source_protocol),
         {:ok, kind} <- bounded_string(attrs, :kind),
         {:ok, affinity} <- affinity(Map.get(attrs, :affinity)),
         :ok <- payload(attrs),
         :ok <- constraints(attrs[:constraints]),
         :ok <- extensions(attrs[:extensions]) do
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

  defp affinity(%Affinity{} = affinity), do: {:ok, affinity}

  defp affinity(attrs) when is_map(attrs) do
    case Affinity.new(attrs) do
      {:ok, affinity} ->
        {:ok, affinity}

      {:error, %Error{message: message}} ->
        {:error, Error.invalid!("Provider state affinity: " <> message)}

      _ ->
        {:error, Error.invalid!("Provider state affinity is invalid")}
    end
  end

  defp affinity(_value), do: {:error, Error.invalid!("Provider state affinity is required")}

  defp payload(attrs) do
    case {attrs[:payload], attrs[:payload_reference]} do
      {nil, nil} ->
        {:error, Error.invalid!("Provider state requires payload or payload_reference")}

      {payload, reference} when payload != nil and reference != nil ->
        {:error,
         Error.invalid!("Provider state cannot contain both payload and payload_reference")}

      {payload, reference} ->
        with :ok <- validate_payload(payload),
             :ok <- validate_payload(reference) do
          :ok
        end
    end
  end

  defp validate_payload(nil), do: :ok

  defp validate_payload(value) when is_binary(value) do
    if byte_size(value) <= Backplane.AiProtocol.Validation.default_limits().max_bytes,
      do: :ok,
      else: {:error, Error.invalid!("Opaque provider state exceeds byte limit")}
  end

  defp validate_payload(value), do: Backplane.AiProtocol.Validation.term(value)

  defp constraints(value), do: bounded_map(value, :constraints)
  defp extensions(value), do: bounded_map(value, :extensions)

  defp bounded_map(nil, _key), do: :ok

  defp bounded_map(value, _key) when is_map(value),
    do: Backplane.AiProtocol.Validation.bounded_map(value)

  defp bounded_map(_value, key),
    do: {:error, Error.invalid!("Provider state #{key} must be a map")}
end
