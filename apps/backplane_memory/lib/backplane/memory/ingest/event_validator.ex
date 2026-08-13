defmodule Backplane.Memory.Ingest.EventValidator do
  @moduledoc "Validates canonical host-capture event envelopes."

  @current_schema 1
  @min_importance -2_147_483_648
  @max_importance 2_147_483_647
  @required ~w(event_id schema_version host_id agent_id integration event_type occurred_at idempotency_key payload_hash privacy payload)
  @identifiers ~w(host_id agent_id integration event_type idempotency_key)
  @optional_identifiers ~w(client_id project scope session_id parent_session_id)
  @canonical_types ~w(conversation.user_message conversation.agent_message tool.call.started agent.session.started agent.prompt.submitted agent.tool.completed agent.tool.failed agent.run.failed agent.context.pre_compact agent.subagent.started agent.subagent.stopped agent.session.stopped agent.session.ended git.commit.created)

  def validate(event) when is_map(event) do
    event = stringify_keys(event)

    case Map.get(event, "schema_version") do
      version when is_integer(version) and version > @current_schema ->
        {:error, :unsupported_schema}

      _version ->
        validate_current(event)
    end
  rescue
    _error -> {:error, {:invalid_event, [:envelope]}}
  end

  def validate(_event), do: {:error, {:invalid_event, [:envelope]}}

  def payload_hash(payload) when is_map(payload) do
    "sha256:" <>
      (:crypto.hash(:sha256, canonical_json(payload))
       |> Base.encode16(case: :lower))
  end

  def payload_hash(_payload), do: nil

  defp validate_current(event) do
    errors =
      []
      |> require_fields(event)
      |> validate_schema(event)
      |> validate_uuid(event)
      |> validate_identifiers(event)
      |> validate_event_type(event)
      |> validate_session(event)
      |> validate_timestamps(event)
      |> validate_importance(event)
      |> validate_maps(event)
      |> validate_trace(event)
      |> validate_payload_hash(event)
      |> Enum.reverse()
      |> Enum.uniq()

    if errors == [] do
      {:ok, normalize_timestamps(event)}
    else
      {:error, {:invalid_event, errors}}
    end
  end

  defp require_fields(errors, event) do
    Enum.reduce(@required, errors, fn field, acc ->
      if Map.has_key?(event, field), do: acc, else: [String.to_atom(field) | acc]
    end)
  end

  defp validate_schema(errors, %{"schema_version" => @current_schema}), do: errors
  defp validate_schema(errors, _event), do: [:schema_version | errors]

  defp validate_uuid(errors, event) do
    case Ecto.UUID.cast(Map.get(event, "event_id")) do
      {:ok, _uuid} -> errors
      :error -> [:event_id | errors]
    end
  end

  defp validate_identifiers(errors, event) do
    errors = Enum.reduce(@identifiers, errors, &validate_required_string(&2, event, &1))

    Enum.reduce(@optional_identifiers, errors, fn field, acc ->
      case Map.fetch(event, field) do
        :error ->
          acc

        {:ok, nil} when field == "parent_session_id" ->
          acc

        {:ok, value} when is_binary(value) ->
          if(String.trim(value) == "", do: [String.to_atom(field) | acc], else: acc)

        {:ok, _value} ->
          [String.to_atom(field) | acc]
      end
    end)
  end

  defp validate_required_string(errors, event, field) do
    case Map.get(event, field) do
      value when is_binary(value) ->
        if(String.trim(value) == "", do: [String.to_atom(field) | errors], else: errors)

      _value ->
        [String.to_atom(field) | errors]
    end
  end

  defp validate_event_type(errors, %{"event_type" => event_type}) when is_binary(event_type) do
    if event_type in @canonical_types, do: errors, else: [:event_type | errors]
  end

  defp validate_event_type(errors, _event), do: [:event_type | errors]

  defp validate_session(errors, event) do
    event_type = Map.get(event, "event_type")

    session_bound? =
      Map.has_key?(event, "session_id") or
        (is_binary(event_type) and String.starts_with?(event_type, "agent."))

    if session_bound? do
      errors
      |> validate_required_string(event, "session_id")
      |> then(fn acc ->
        if is_integer(event["sequence"]) and event["sequence"] > 0,
          do: acc,
          else: [:sequence | acc]
      end)
    else
      errors
    end
  end

  defp validate_timestamps(errors, event) do
    Enum.reduce(~w(occurred_at captured_at), errors, fn field, acc ->
      case Map.fetch(event, field) do
        :error when field == "captured_at" -> acc
        {:ok, value} -> if(valid_datetime?(value), do: acc, else: [String.to_atom(field) | acc])
        :error -> [String.to_atom(field) | acc]
      end
    end)
  end

  defp validate_importance(errors, event) do
    case Map.fetch(event, "importance") do
      :error ->
        errors

      {:ok, value}
      when is_integer(value) and value >= @min_importance and value <= @max_importance ->
        errors

      {:ok, _value} ->
        [:importance | errors]
    end
  end

  defp validate_maps(errors, event) do
    Enum.reduce(~w(payload privacy trace), errors, fn field, acc ->
      case Map.fetch(event, field) do
        :error when field == "trace" ->
          acc

        {:ok, value} when is_map(value) ->
          if(json_value?(value), do: acc, else: [String.to_atom(field) | acc])

        _other ->
          [String.to_atom(field) | acc]
      end
    end)
  end

  defp validate_trace(errors, %{"trace" => trace}) when is_map(trace) do
    errors =
      case Map.fetch(trace, "correlation_id") do
        :error -> errors
        {:ok, value} when is_binary(value) -> errors
        {:ok, _value} -> [:trace | errors]
      end

    case Map.fetch(trace, "causation_id") do
      :error ->
        errors

      {:ok, nil} ->
        errors

      {:ok, value} ->
        if(match?({:ok, _}, Ecto.UUID.cast(value)), do: errors, else: [:trace | errors])
    end
  end

  defp validate_trace(errors, _event), do: errors

  defp validate_payload_hash(errors, %{"payload" => payload, "payload_hash" => hash})
       when is_map(payload) and is_binary(hash) do
    if hash == payload_hash(payload), do: errors, else: [:payload_hash | errors]
  end

  defp validate_payload_hash(errors, _event), do: [:payload_hash | errors]

  defp normalize_timestamps(event) do
    Enum.reduce(~w(occurred_at captured_at), event, fn field, acc ->
      case Map.fetch(acc, field) do
        {:ok, value} -> Map.put(acc, field, cast_datetime(value))
        :error -> acc
      end
    end)
  end

  defp valid_datetime?(%DateTime{}), do: true

  defp valid_datetime?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_datetime?(_value), do: false

  defp cast_datetime(%DateTime{} = value),
    do: value |> DateTime.shift_zone!("Etc/UTC") |> microsecond_precision()

  defp cast_datetime(value),
    do:
      value
      |> DateTime.from_iso8601()
      |> elem(1)
      |> DateTime.shift_zone!("Etc/UTC")
      |> microsecond_precision()

  defp microsecond_precision(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp json_value?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and json_value?(value) end)

  defp json_value?([]), do: true
  defp json_value?([head | tail]), do: json_value?(head) and json_value?(tail)

  defp json_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_value?(_value), do: false

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(key) <> ":" <> canonical_json(value)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)
end
