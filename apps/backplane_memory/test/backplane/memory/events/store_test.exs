defmodule Backplane.Memory.Events.StoreTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Events.{Event, Store, Stream}

  test "append returns untagged events while append_multi keeps its internal result tag" do
    stream_id = unique("public")

    assert {:ok, %Event{} = first} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "conversation.user_message",
               content: "first"
             })

    assert first.sequence == 1

    assert {:ok, %Event{} = second} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "conversation.agent_message",
               content: "second"
             })

    assert second.sequence == 2

    multi =
      Store.append_multi(Ecto.Multi.new(), :event, %{
        stream_id: stream_id,
        event_type: "task.created"
      })

    assert {:ok, %{event: {:inserted, %Event{} = third}}} = repo().transaction(multi)
    assert third.sequence == 3
  end

  test "append_multi represents normalization failures as Multi errors before execution" do
    parent = self()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:db_operation, fn _repo, _changes ->
        send(parent, :db_operation_ran)
        {:ok, :ran}
      end)
      |> Store.append_multi(:event, %{event_type: "task.created"})

    assert {:error, :missing_identity} = Keyword.fetch!(Ecto.Multi.to_list(multi), :event)
    assert {:error, :event, :missing_identity, %{}} = repo().transaction(multi)
    refute_received :db_operation_ran
  end

  test "exact global-key duplicate returns the original event without moving the cursor" do
    stream_id = unique("duplicate")
    key = unique("key")

    attrs = %{
      stream_id: stream_id,
      event_type: "tool.call.completed",
      content: "stable",
      payload: %{"result" => "ok"},
      idempotency_key: key
    }

    assert {:ok, first} = Store.append(attrs)
    assert {:ok, duplicate} = Store.append(attrs)
    assert duplicate.id == first.id

    assert %Stream{next_sequence: 2} = repo().get!(Stream, stream_id)
    assert repo().aggregate(from(e in Event, where: e.idempotency_key == ^key), :count) == 1
  end

  test "global idempotency conflicts on changed type, content, payload, or stream" do
    stream_id = unique("conflict")

    for {label, change} <- [
          {:type, %{event_type: "tool.call.failed"}},
          {:content, %{content: "changed"}},
          {:payload, %{payload: %{"result" => "changed"}}},
          {:stream, %{stream_id: unique("other")}}
        ] do
      key = unique("conflict-#{label}")

      attrs = %{
        stream_id: stream_id,
        event_type: "tool.call.completed",
        content: "stable",
        payload: %{"result" => "ok"},
        idempotency_key: key
      }

      assert {:ok, _event} = Store.append(attrs)

      assert {:error, :idempotency_conflict} =
               attrs
               |> Map.merge(change)
               |> Store.append()
    end
  end

  test "missing persisted fingerprint is an idempotency conflict" do
    stream_id = unique("missing-fingerprint")
    key = unique("key")

    assert {:ok, event} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "tool.call.completed",
               content: "stable"
             })

    repo().update_all(from(e in Event, where: e.id == ^event.id),
      set: [idempotency_key: key]
    )

    assert {:error, :idempotency_conflict} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "tool.call.completed",
               content: "stable",
               idempotency_key: key
             })
  end

  test "exact replay after closure succeeds but a new closed-stream append fails" do
    stream_id = unique("closed")

    attrs = %{
      stream_id: stream_id,
      event_type: "session.started",
      idempotency_key: unique("started")
    }

    assert {:ok, first} = Store.append(attrs)
    assert {:ok, _stream} = Store.close_stream(stream_id)

    assert {:ok, replay} = Store.append(attrs)
    assert replay.id == first.id

    assert {:error, :stream_closed} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "session.ended",
               idempotency_key: unique("ended")
             })

    assert [%Event{sequence: 1}] = Store.list(stream_id)
  end

  test "stream metadata is initialized, fills nulls, and never overwrites non-null fields" do
    initial_stream_id = unique("metadata-initial")

    assert {:ok, _} =
             Store.append(%{
               stream_id: initial_stream_id,
               event_type: "session.started",
               project: "initial-project",
               agent_id: "initial-agent",
               host_id: "initial-host",
               client_id: "initial-client",
               session_id: "initial-session",
               run_id: "initial-run"
             })

    assert %Stream{
             project: "initial-project",
             agent_id: "initial-agent",
             host_id: "initial-host",
             client_id: "initial-client",
             session_id: "initial-session",
             run_id: "initial-run"
           } = repo().get!(Stream, initial_stream_id)

    stream_id = unique("metadata")

    assert {:ok, _} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "session.started",
               project: "project-one",
               session_id: "session-one"
             })

    assert {:ok, _} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "agent.run.started",
               project: "project-two",
               agent_id: "agent-one",
               host_id: "host-one",
               client_id: "client-one",
               session_id: "session-two",
               run_id: "run-one"
             })

    assert %Stream{
             project: "project-one",
             agent_id: "agent-one",
             host_id: "host-one",
             client_id: "client-one",
             session_id: "session-one",
             run_id: "run-one"
           } = repo().get!(Stream, stream_id)

    assert {:ok, _} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "agent.run.completed",
               project: "project-three",
               agent_id: "agent-two",
               host_id: "host-two",
               client_id: "client-two",
               session_id: "session-three",
               run_id: "run-two"
             })

    assert %Stream{
             project: "project-one",
             agent_id: "agent-one",
             host_id: "host-one",
             client_id: "client-one",
             session_id: "session-one",
             run_id: "run-one"
           } = repo().get!(Stream, stream_id)
  end

  test "last_event_at keeps the greatest occurred_at rather than append order" do
    stream_id = unique("last-event")
    newer = ~U[2026-07-16 12:00:00.000000Z]
    older = ~U[2026-07-15 12:00:00.000000Z]

    assert {:ok, _} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "task.created",
               occurred_at: newer
             })

    assert {:ok, _} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "task.updated",
               occurred_at: older
             })

    assert repo().get!(Stream, stream_id).last_event_at == newer
  end

  test "a later outer Multi failure rolls back event, stream metadata, and cursor" do
    stream_id = unique("outer-rollback")

    attrs = %{
      stream_id: stream_id,
      event_type: "task.created",
      project: "rollback-project",
      idempotency_key: unique("rollback-key")
    }

    multi =
      Ecto.Multi.new()
      |> Store.append_multi(:event, attrs)
      |> Ecto.Multi.run(:deliberate_failure, fn _repo, _changes ->
        {:error, :deliberate_failure}
      end)

    assert {:error, :deliberate_failure, :deliberate_failure, %{event: {:inserted, _}}} =
             repo().transaction(multi)

    refute repo().get(Stream, stream_id)
    refute repo().get_by(Event, idempotency_key: attrs.idempotency_key)

    assert {:ok, %Event{sequence: 1}} = Store.append(attrs)
  end

  test "batch locks streams canonically and returns events in original input order" do
    stream_a = unique("a")
    stream_b = unique("b")

    attrs = [
      event(stream_b, "B1"),
      event(stream_a, "A1"),
      event(stream_b, "B2"),
      event(stream_a, "A2")
    ]

    assert {:ok, events} = Store.append_batch(attrs)

    assert Enum.map(events, & &1.content) == ["B1", "A1", "B2", "A2"]
    assert Enum.map(events, & &1.sequence) == [1, 1, 2, 2]
  end

  test "batch validation, closure, and idempotency conflicts roll back every change" do
    validation_stream = unique("batch-validation")

    assert {:error, :missing_identity} =
             Store.append_batch([
               event(validation_stream, "valid"),
               %{event_type: "task.created"}
             ])

    refute repo().get(Stream, validation_stream)

    closed_stream = unique("batch-closed")
    open_stream = unique("batch-open")
    assert {:ok, _} = Store.append(event(closed_stream, "seed"))
    assert {:ok, _} = Store.close_stream(closed_stream)

    assert {:error, :stream_closed} =
             Store.append_batch([
               event(open_stream, "open"),
               event(closed_stream, "closed")
             ])

    refute repo().get(Stream, open_stream)

    conflict_stream = unique("batch-conflict")
    rollback_stream = unique("batch-rollback")
    key = unique("batch-key")
    assert {:ok, existing} = Store.append(event(conflict_stream, "stable", key))

    assert {:error, :idempotency_conflict} =
             Store.append_batch([
               event(rollback_stream, "must roll back"),
               event(conflict_stream, "changed", key)
             ])

    refute repo().get(Stream, rollback_stream)
    assert repo().get!(Stream, conflict_stream).next_sequence == 2
    assert repo().get!(Event, existing.id).content == "stable"
  end

  test "error telemetry contains no attributes, content, payload, or raw reason" do
    handler_id = "store-safe-error-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :memory, :event, :ingest],
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    raw_secret = "store-telemetry-secret"

    assert {:error, :missing_identity} =
             Store.append(%{
               event_type: "tool.call.failed",
               content: raw_secret,
               payload: %{"secret" => raw_secret}
             })

    assert_receive {:telemetry, _, %{count: 0}, metadata}
    assert metadata == %{status: :error}
    refute inspect(metadata) =~ raw_secret
    refute inspect(metadata) =~ "missing_identity"
  end

  test "success telemetry bounds stream metadata" do
    handler_id = "store-bounded-success-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :memory, :event, :ingest],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry_metadata, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stream_id = unique(String.duplicate("long-stream", 100))
    assert {:ok, _event} = Store.append(%{stream_id: stream_id, event_type: "task.created"})

    assert_receive {:telemetry_metadata, metadata}
    assert metadata.status == :inserted
    assert byte_size(metadata.stream_id) <= 256
  end

  test "append_multi and telemetry false emit nothing while emit_result accepts a public event" do
    handler_id = "store-telemetry-control-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:backplane, :memory, :event, :ingest],
        fn _event, _measurements, metadata, _ ->
          send(parent, {:telemetry_metadata, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    multi =
      Store.append_multi(Ecto.Multi.new(), :event, %{
        stream_id: unique("multi-no-telemetry"),
        event_type: "task.created"
      })

    assert {:ok, %{event: {:inserted, _event}}} = repo().transaction(multi)
    refute_receive {:telemetry_metadata, _}

    assert {:ok, event} =
             Store.append(
               %{stream_id: unique("disabled-telemetry"), event_type: "task.created"},
               telemetry: false
             )

    refute_receive {:telemetry_metadata, _}

    Store.emit_result({:ok, event})
    assert_receive {:telemetry_metadata, %{status: :inserted}}
  end

  defp event(stream_id, content, idempotency_key \\ nil) do
    %{
      stream_id: stream_id,
      event_type: "task.created",
      content: content,
      idempotency_key: idempotency_key
    }
  end

  defp unique(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
