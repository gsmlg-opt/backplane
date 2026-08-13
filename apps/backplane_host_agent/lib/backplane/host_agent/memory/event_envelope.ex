defmodule Backplane.HostAgent.Memory.EventEnvelope do
  @moduledoc "Canonical host-capture event envelope, schema version 1."

  @required ~w(event_id schema_version host_id agent_id integration event_type occurred_at idempotency_key payload_hash privacy payload)
  @optional ~w(client_id project scope parent_session_id captured_at trace session_id sequence)
  @identifiers ~w(event_id host_id agent_id integration event_type idempotency_key)

  @type t :: %{required(String.t()) => term()}

  @doc "Normalizes and validates input as a canonical v1 envelope."
  @spec build(map()) :: {:ok, t()} | {:error, [atom()]}
  def build(attrs), do: validate(attrs)

  @doc "Validates input and returns a string-keyed wire envelope."
  @spec validate(map()) :: {:ok, t()} | {:error, [atom()]}
  def validate(attrs) when is_map(attrs) do
    case fetch_payload(attrs) do
      {:ok, payload} ->
        if valid_payload?(payload), do: validate_normalized(attrs), else: {:error, [:payload]}

      :error ->
        validate_normalized(attrs)
    end
  end

  def validate(_), do: {:error, [:envelope]}

  @doc "Returns whether a payload can be represented as canonical JSON."
  def valid_payload?(payload) when is_map(payload), do: json_value?(payload)
  def valid_payload?(_payload), do: false

  defp validate_normalized(attrs) do
    envelope =
      attrs
      |> stringify_keys()
      |> Map.take(@required ++ @optional)

    errors =
      []
      |> require_fields(envelope)
      |> validate_schema(envelope)
      |> validate_identifiers(envelope)
      |> validate_session(envelope)
      |> validate_timestamps(envelope)
      |> validate_maps(envelope)
      |> validate_hash(envelope)
      |> Enum.reverse()
      |> Enum.uniq()

    if errors == [], do: {:ok, envelope}, else: {:error, errors}
  end

  @doc "Encodes an already canonical envelope."
  def encode!(envelope), do: Jason.encode!(envelope)

  @doc "Returns the deterministic SHA-256 hash of canonical filtered payload JSON."
  def payload_hash(payload) when is_map(payload) do
    canonical = payload |> stringify_keys() |> canonical_json()
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  defp require_fields(errors, envelope) do
    Enum.reduce(@required, errors, fn field, acc ->
      if Map.has_key?(envelope, field), do: acc, else: [String.to_atom(field) | acc]
    end)
  end

  defp validate_schema(errors, %{"schema_version" => 1}), do: errors
  defp validate_schema(errors, _), do: [:schema_version | errors]

  defp validate_identifiers(errors, envelope) do
    Enum.reduce(@identifiers, errors, fn field, acc ->
      case Map.get(envelope, field) do
        value when is_binary(value) ->
          if String.trim(value) == "", do: [String.to_atom(field) | acc], else: acc

        _ ->
          [String.to_atom(field) | acc]
      end
    end)
  end

  defp validate_session(errors, envelope) do
    event_type = Map.get(envelope, "event_type")

    session_bound? =
      Map.has_key?(envelope, "session_id") or
        (is_binary(event_type) and String.starts_with?(event_type, "agent."))

    if session_bound? do
      errors
      |> check_nonblank(envelope, "session_id")
      |> then(fn acc ->
        if is_integer(envelope["sequence"]) and envelope["sequence"] > 0,
          do: acc,
          else: [:sequence | acc]
      end)
    else
      errors
    end
  end

  defp check_nonblank(errors, envelope, field) do
    case Map.get(envelope, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: [String.to_atom(field) | errors], else: errors

      _ ->
        [String.to_atom(field) | errors]
    end
  end

  defp validate_timestamps(errors, envelope) do
    Enum.reduce(~w(occurred_at captured_at), errors, fn field, acc ->
      case Map.fetch(envelope, field) do
        :error when field == "captured_at" ->
          acc

        {:ok, value} when is_binary(value) ->
          if match?({:ok, _, _}, DateTime.from_iso8601(value)),
            do: acc,
            else: [String.to_atom(field) | acc]

        _ ->
          [String.to_atom(field) | acc]
      end
    end)
  end

  defp validate_maps(errors, envelope) do
    Enum.reduce(~w(privacy payload trace), errors, fn field, acc ->
      case Map.fetch(envelope, field) do
        :error when field == "trace" -> acc
        {:ok, value} when is_map(value) -> acc
        _ -> [String.to_atom(field) | acc]
      end
    end)
  end

  defp validate_hash(errors, %{"payload" => payload, "payload_hash" => hash})
       when is_map(payload) do
    if hash == payload_hash(payload), do: errors, else: [:payload_hash | errors]
  end

  defp validate_hash(errors, _), do: errors

  defp fetch_payload(attrs) do
    cond do
      Map.has_key?(attrs, :payload) -> {:ok, Map.get(attrs, :payload)}
      Map.has_key?(attrs, "payload") -> {:ok, Map.get(attrs, "payload")}
      true -> :error
    end
  end

  defp json_value?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      (is_binary(key) or is_atom(key)) and json_value?(value)
    end)
  end

  defp json_value?([]), do: true

  defp json_value?([head | tail]) do
    json_value?(head) and json_list_tail?(tail)
  end

  defp json_value?(value) when is_binary(value) or is_number(value), do: true
  defp json_value?(value) when value in [nil, true, false], do: true
  defp json_value?(_value), do: false

  defp json_list_tail?([]), do: true

  defp json_list_tail?([head | tail]) do
    json_value?(head) and json_list_tail?(tail)
  end

  defp json_list_tail?(_improper_tail), do: false

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(key) <> ":" <> canonical_json(value)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)
end
