defmodule Backplane.Memory.Ingest do
  @moduledoc """
  Authenticated, partial-ACK ingestion of canonical capture events.

  The caller must provide the authenticated host token's scopes and a trusted partition.
  Canonical host, client, scope, and namespace fields come only from that partition. Event
  `agent_id`, `project`, `scope`, and `client_id` remain provenance supplied by the host.
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
  @v1_authority_keys ~w(memory_space_id partition_id namespace)
  @v1_authority_atom_keys ~w(memory_space_id partition_id namespace)a
  @prepared_partition_fields ~w(host_id client_id scope namespace integration ingest_auth_token_id)a

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
        results =
          case resolve_partition(auth_context) do
            {:ok, partition} ->
              auth_context
              |> Map.put(:partition, partition)
              |> ingest_events(events, opts)

            {:error, :invalid_partition} ->
              Enum.map(events, &rejected(get(&1, :event_id), "invalid_partition"))
          end

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
      with :ok <- authorize_partition_claims(auth_context, event),
           {:ok, event} <- EventValidator.validate(event),
           {:ok, event} <- server_filter(event),
           {:ok, attrs} <- Upcaster.V1.upcast(event, auth_context),
           :ok <- validate_prepared_partition(attrs) do
        {:persist, event_id, attrs}
      else
        {:error, :partition_mismatch} ->
          {:reply, rejected(event_id, "partition_mismatch")}

        {:error, :invalid_partition} ->
          {:reply, rejected(event_id, "invalid_partition")}

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

  defp authorize_partition_claims(auth_context, event) do
    partition = get(auth_context, :partition)
    authenticated = get(partition, :host_id)
    claimed = get(event, :host_id)

    if authenticated == claimed and not authority_claim?(event),
      do: :ok,
      else: {:error, :partition_mismatch}
  end

  defp authority_claim?(event) when is_map(event) do
    Enum.any?(@v1_authority_keys, &Map.has_key?(event, &1)) or
      Enum.any?(@v1_authority_atom_keys, &Map.has_key?(event, &1))
  end

  defp authority_claim?(_event), do: false

  defp resolve_partition(auth_context) do
    host_id = get(auth_context, :host_id)
    partition = get(auth_context, :partition)
    partition_host_id = get(partition, :host_id)
    partition_id = get(partition, :partition_id)
    scope = get(partition, :scope)
    namespace = get(partition, :namespace)

    if non_empty_binary?(host_id) and partition_host_id == host_id and
         partition_id == "host:#{host_id}" and non_empty_binary?(scope) and
         namespace == "private" do
      {:ok,
       %{
         host_id: host_id,
         partition_id: partition_id,
         scope: scope,
         namespace: namespace
       }}
    else
      {:error, :invalid_partition}
    end
  end

  defp capture_authorized?(auth_context) do
    "host_agent.capture" in (get(auth_context, :scopes) || []) and
      non_empty_binary?(get(auth_context, :auth_token_id))
  end

  defp non_empty_binary?(value),
    do: is_binary(value) and String.trim(value) != ""

  defp server_filter(event) do
    with {:ok, payload} <- Filter.apply_payload(event["payload"]),
         {:ok, source_client_id} <- filter_optional_provenance(event["client_id"]),
         {:ok, source_scope} <- filter_optional_provenance(event["scope"]) do
      payload_hash = EventValidator.payload_hash(payload)

      {:ok,
       event
       |> Map.put("payload", payload)
       |> Map.put("payload_hash", payload_hash)
       |> maybe_put_provenance("client_id", source_client_id)
       |> maybe_put_provenance("scope", source_scope)
       |> Map.update(
         "privacy",
         %{"server_filtered" => true},
         &Map.put(&1, "server_filtered", true)
       )}
    end
  end

  defp filter_optional_provenance(nil), do: {:ok, nil}
  defp filter_optional_provenance(value), do: Filter.apply(value)

  defp maybe_put_provenance(event, _key, nil), do: event
  defp maybe_put_provenance(event, key, value), do: Map.put(event, key, value)

  defp validate_prepared_partition(attrs) when is_map(attrs) do
    complete_fields? =
      Enum.all?(@prepared_partition_fields, &non_empty_binary?(Map.get(attrs, &1)))

    raw_envelope = Map.get(attrs, :raw_envelope)

    if complete_fields? and is_map(raw_envelope) and not is_struct(raw_envelope) and
         map_size(raw_envelope) > 0,
       do: :ok,
       else: {:error, :invalid_partition}
  end

  defp validate_prepared_partition(_attrs), do: {:error, :invalid_partition}

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
