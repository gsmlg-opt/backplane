defmodule Backplane.Memory.Ingest.Upcaster.V1 do
  @moduledoc "Maps canonical capture envelope version 1 into event-store attributes."

  def upcast(%{"schema_version" => 1} = event, auth_context) do
    host_id = fetch(auth_context, :host_id)
    auth_token_id = fetch(auth_context, :auth_token_id)
    partition_id = "host:" <> host_id
    session_id = event["session_id"]

    {:ok,
     %{
       id: event["event_id"],
       stream_id: stream_id(host_id, session_id, event["event_id"]),
       project: event["project"],
       namespace: "private",
       agent_id: event["agent_id"],
       host_id: host_id,
       client_id: partition_id,
       session_id: session_id,
       event_type: event["event_type"],
       correlation_id: get_in(event, ["trace", "correlation_id"]),
       causation_id: get_in(event, ["trace", "causation_id"]),
       idempotency_key: namespaced_idempotency_key(host_id, event["idempotency_key"]),
       importance: event["importance"] || 0,
       payload: event["payload"],
       occurred_at: event["occurred_at"],
       schema_version: 1,
       integration: event["integration"],
       scope: event["scope"],
       parent_session_id: event["parent_session_id"],
       source_sequence: event["sequence"],
       captured_at: event["captured_at"],
       payload_hash: event["payload_hash"],
       privacy: event["privacy"],
       trace: event["trace"] || %{},
       raw_envelope: event |> Map.put("client_id", partition_id) |> wire_envelope(),
       ingest_auth_token_id: auth_token_id
     }}
  end

  def upcast(_event, _auth_context), do: {:error, :unsupported_schema}

  defp stream_id(host_id, session_id, _event_id) when is_binary(session_id),
    do: "capture:#{host_id}:#{session_id}"

  defp stream_id(host_id, nil, event_id), do: "capture:#{host_id}:event:#{event_id}"

  defp namespaced_idempotency_key(host_id, idempotency_key),
    do: "capture:#{byte_size(host_id)}:#{host_id}:#{idempotency_key}"

  defp wire_envelope(event) do
    Map.new(event, fn
      {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
      pair -> pair
    end)
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
