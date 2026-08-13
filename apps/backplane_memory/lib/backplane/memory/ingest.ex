defmodule Backplane.Memory.Ingest do
  @moduledoc """
  Authenticated, partial-ACK ingestion of canonical capture events.

  The caller must provide the authenticated host token's canonical scopes.
  The token ID is the trusted client identity persisted by this boundary; event `agent_id`,
  `project`, and `scope` remain provenance supplied by that authenticated host.
  """

  @transient_reasons [:database_unavailable, :transaction_rolled_back, :timeout, :disconnected]
  @transient_postgres_codes [
    :serialization_failure,
    :deadlock_detected,
    :query_canceled,
    :connection_exception,
    :connection_does_not_exist,
    :connection_failure,
    :sqlclient_unable_to_establish_sqlconnection,
    :sqlserver_rejected_establishment_of_sqlconnection,
    :protocol_violation
  ]
  @permanent_domain_reasons [
    :stream_closed,
    :stream_metadata_conflict,
    :invalid_attributes,
    :invalid_attributes_type,
    :invalid_event_type,
    :missing_identity,
    :invalid_payload,
    :invalid_importance,
    :invalid_time,
    :invalid_uuid,
    :invalid_utf8,
    :conflicting_keys
  ]

  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Ingest.{EventValidator, Upcaster}
  alias Backplane.Memory.Privacy.Filter

  def ingest_batch(auth_context, batch, opts \\ [])

  def ingest_batch(auth_context, batch, opts) when is_map(auth_context) and is_map(batch) do
    batch_id = get(batch, :batch_id)
    batch_host_id = get(batch, :host_id)
    events = get(batch, :events)

    cond do
      not capture_authorized?(auth_context) ->
        {:error, :capture_unauthorized}

      not (is_binary(batch_host_id) and String.trim(batch_host_id) != "") ->
        {:error, :invalid_batch}

      batch_host_id != get(auth_context, :host_id) ->
        {:error, :host_mismatch}

      not proper_list?(events) ->
        {:error, :invalid_batch}

      true ->
        results = ingest_events(auth_context, events, opts)
        {:ok, %{"batch_id" => batch_id, "results" => results}}
    end
  end

  def ingest_batch(_auth_context, _batch, _opts), do: {:error, :invalid_batch}

  defp ingest_events(auth_context, events, opts) do
    prepared = Enum.map(events, &prepare_event(auth_context, &1))
    store = Keyword.get(opts, :store, Store)

    if function_exported?(store, :append_batch_tagged, 2) do
      persist_prepared_batch(prepared, store, opts)
    else
      Enum.map(prepared, &persist_prepared(&1, opts))
    end
  end

  defp prepare_event(auth_context, event) do
    event_id = get(event, :event_id)

    try do
      with :ok <- authorize_host(auth_context, event),
           {:ok, event} <- EventValidator.validate(event),
           {:ok, event} <- server_filter(event),
           {:ok, attrs} <- Upcaster.V1.upcast(event, auth_context) do
        {:persist, event_id, attrs}
      else
        {:error, :host_mismatch} ->
          {:reply, rejected(event_id, "host_mismatch")}

        {:error, :unsupported_schema} ->
          {:reply, rejected(event_id, "unsupported_schema")}

        {:error, {:invalid_event, _errors}} ->
          {:reply, rejected(event_id, "invalid_event")}

        {:error, reason} when reason in [:invalid_payload, :invalid_utf8] ->
          {:reply, rejected(event_id, "invalid_event")}

        {:error, reason} ->
          {:reply, failed(event_id, reason)}
      end
    rescue
      _error in DBConnection.ConnectionError ->
        {:reply, failed(event_id, :database_unavailable)}

      error in Postgrex.Error ->
        if transient_storage_reason?(error),
          do: {:reply, failed(event_id, error)},
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp persist_prepared_batch(prepared, store, opts) do
    entries = Enum.filter(prepared, &match?({:persist, _, _}, &1))
    attrs = Enum.map(entries, &elem(&1, 2))
    store_opts = Keyword.take(opts, [:repo, :telemetry])

    persisted_replies =
      case safe_append_batch(store, attrs, store_opts) do
        {:ok, tagged} ->
          Enum.zip_with(entries, tagged, fn {:persist, event_id, _attrs}, {status, event} ->
            case status do
              :inserted -> accepted(event_id, event.id)
              :duplicate -> duplicate(event_id, event.id)
            end
          end)

        {:error, reason} when reason in @transient_reasons ->
          Enum.map(entries, fn {:persist, event_id, _attrs} -> failed(event_id, reason) end)

        {:error, %DBConnection.ConnectionError{} = reason} ->
          Enum.map(entries, fn {:persist, event_id, _attrs} -> failed(event_id, reason) end)

        {:error, %Postgrex.Error{} = reason} ->
          if transient_storage_reason?(reason) do
            Enum.map(entries, fn {:persist, event_id, _attrs} -> failed(event_id, reason) end)
          else
            persist_entries_individually(entries, opts)
          end

        {:error, _reason} ->
          persist_entries_individually(entries, opts)
      end

    {results, []} =
      Enum.map_reduce(prepared, persisted_replies, fn
        {:reply, reply}, remaining -> {reply, remaining}
        {:persist, _, _}, [reply | remaining] -> {reply, remaining}
      end)

    results
  end

  defp safe_append_batch(store, attrs, store_opts) do
    store.append_batch_tagged(attrs, store_opts)
  rescue
    error in DBConnection.ConnectionError ->
      {:error, error}

    error in Postgrex.Error ->
      if transient_storage_reason?(error),
        do: {:error, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp persist_entries_individually(entries, opts) do
    Enum.map(entries, fn {:persist, event_id, attrs} -> safe_persist(event_id, attrs, opts) end)
  end

  defp persist_prepared({:reply, reply}, _opts), do: reply

  defp persist_prepared({:persist, event_id, attrs}, opts),
    do: safe_persist(event_id, attrs, opts)

  defp safe_persist(event_id, attrs, opts) do
    persist(event_id, attrs, opts)
  rescue
    _error in DBConnection.ConnectionError ->
      failed(event_id, :database_unavailable)

    error in Postgrex.Error ->
      if transient_storage_reason?(error),
        do: failed(event_id, error),
        else: reraise(error, __STACKTRACE__)
  end

  defp authorize_host(auth_context, event) do
    authenticated = get(auth_context, :host_id)
    claimed = get(event, :host_id)

    if is_binary(authenticated) and authenticated == claimed,
      do: :ok,
      else: {:error, :host_mismatch}
  end

  defp capture_authorized?(auth_context) do
    "host_agent.capture" in (get(auth_context, :scopes) || []) and
      non_empty_binary?(get(auth_context, :auth_token_id))
  end

  defp non_empty_binary?(value),
    do: is_binary(value) and String.trim(value) != ""

  defp server_filter(event) do
    with {:ok, payload} <- Filter.apply_payload(event["payload"]) do
      payload_hash = EventValidator.payload_hash(payload)

      {:ok,
       event
       |> Map.put("payload", payload)
       |> Map.put("payload_hash", payload_hash)
       |> Map.update(
         "privacy",
         %{"server_filtered" => true},
         &Map.put(&1, "server_filtered", true)
       )}
    end
  end

  defp persist(event_id, attrs, opts) do
    store = Keyword.get(opts, :store, Store)
    store_opts = Keyword.take(opts, [:repo, :telemetry])

    case store.append_tagged(attrs, store_opts) do
      {:ok, {:inserted, event}} ->
        accepted(event_id, event.id)

      {:ok, {:duplicate, event}} ->
        duplicate(event_id, event.id)

      {:error, :idempotency_conflict} ->
        rejected(event_id, "identity_conflict")

      {:error, reason}
      when reason in [
             :event_id_unique_violation,
             :idempotency_unique_violation,
             :source_identity_unique_violation
           ] ->
        rejected(event_id, "identity_conflict")

      {:error, %Ecto.Changeset{}} ->
        rejected(event_id, "invalid_event")

      {:error, reason} ->
        classify_store_error(event_id, reason)
    end
  end

  defp accepted(event_id, server_id),
    do: %{"event_id" => event_id, "status" => "accepted", "server_event_id" => server_id}

  defp duplicate(event_id, server_id),
    do: %{"event_id" => event_id, "status" => "duplicate", "server_event_id" => server_id}

  defp rejected(event_id, reason),
    do: %{
      "event_id" => event_id,
      "status" => "rejected",
      "retryable" => false,
      "reason" => reason
    }

  defp failed(event_id, reason),
    do: %{
      "event_id" => event_id,
      "status" => "failed",
      "retryable" => true,
      "reason" => reason_string(reason)
    }

  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(_reason), do: "storage_error"

  defp classify_store_error(event_id, reason) do
    cond do
      transient_storage_reason?(reason) -> failed(event_id, reason)
      permanent_domain_reason?(reason) -> rejected(event_id, reason_string(reason))
      true -> raise "unexpected event store error: #{inspect(reason)}"
    end
  end

  defp transient_storage_reason?(reason) when reason in @transient_reasons, do: true
  defp transient_storage_reason?(%DBConnection.ConnectionError{}), do: true

  defp transient_storage_reason?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @transient_postgres_codes

  defp transient_storage_reason?(_reason), do: false

  defp permanent_domain_reason?(reason) when reason in @permanent_domain_reasons, do: true
  defp permanent_domain_reason?({:invalid_key, _key}), do: true
  defp permanent_domain_reason?(_reason), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_value), do: false

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_value, _key), do: nil
end
