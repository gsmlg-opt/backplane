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

  test "invalid batch attributes return an error even when options are not a keyword list" do
    attach_event_telemetry()

    assert {:error, :invalid_attributes} = Store.append_batch(:invalid, %{})

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :error],
                    %{duration: duration, content_bytes: 0, payload_bytes: 0}, %{status: :error}}

    assert duration >= 0
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

  test "append telemetry has exact safe measurements and bounded metadata" do
    attach_event_telemetry()

    secret = "store-telemetry-secret"
    stream_id = unique(String.duplicate("long-世界", 80))

    assert {:ok, event} =
             Store.append(%{
               stream_id: stream_id,
               event_type: "tool.call.completed",
               project: String.duplicate("项目", 100),
               agent_id: "agent",
               session_id: "session",
               run_id: "run",
               content: "safe content",
               payload: %{"result" => "ok"},
               idempotency_key: secret
             })

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], measurements,
                    metadata}

    assert Map.keys(measurements) |> Enum.sort() == [:content_bytes, :duration, :payload_bytes]
    assert measurements.duration >= 0
    assert measurements.content_bytes == byte_size(event.content)
    assert measurements.payload_bytes == byte_size(Jason.encode!(event.payload))

    assert Map.keys(metadata) |> Enum.sort() ==
             [:agent_id, :event_type, :project, :run_id, :session_id, :status, :stream_id]

    assert metadata.status == :inserted

    for value <- Map.values(Map.delete(metadata, :status)), is_binary(value) do
      assert byte_size(value) <= 256
      assert String.valid?(value)
    end

    emitted = inspect({measurements, metadata})
    refute emitted =~ secret
    refute emitted =~ "safe content"
    refute emitted =~ "result"
    refute_receive {:event_telemetry, [:backplane, :memory, :event, :ingest], _, _}
  end

  test "duplicate and error telemetry use exact event names without leaking inputs or reasons" do
    attach_event_telemetry()
    stream_id = unique("telemetry-outcomes")
    key = unique("telemetry-key")
    attrs = event(stream_id, "stable", key)

    assert {:ok, original} = Store.append(attrs)
    assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], _, _}

    assert {:ok, duplicate} = Store.append(attrs)
    assert duplicate.id == original.id

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :duplicate], measurements,
                    %{status: :duplicate}}

    assert measurements.content_bytes == byte_size(duplicate.content)
    assert measurements.payload_bytes == byte_size(Jason.encode!(duplicate.payload))
    assert measurements.duration >= 0

    raw_secret = "changed-secret"

    assert {:error, :idempotency_conflict} =
             Store.append(
               Map.merge(attrs, %{content: raw_secret, payload: %{"headers" => raw_secret}})
             )

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :error], error_measurements,
                    error_metadata}

    assert error_measurements == %{
             duration: error_measurements.duration,
             content_bytes: 0,
             payload_bytes: 0
           }

    assert error_measurements.duration >= 0

    assert error_metadata == %{
             stream_id: nil,
             event_type: nil,
             project: nil,
             agent_id: nil,
             session_id: nil,
             run_id: nil,
             status: :error
           }

    emitted = inspect({error_measurements, error_metadata})
    refute emitted =~ raw_secret
    refute emitted =~ "headers"
    refute emitted =~ "idempotency_conflict"
  end

  test "validation errors emit one safe error while telemetry false and append_multi stay silent" do
    attach_event_telemetry()

    assert {:error, :missing_identity} =
             Store.append(%{
               event_type: "tool.call.failed",
               content: "unpersisted secret",
               payload: %{"secret" => "unpersisted secret"}
             })

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :error],
                    %{duration: duration, content_bytes: 0, payload_bytes: 0}, %{status: :error}}

    assert duration >= 0
    refute_receive {:event_telemetry, _, _, _}

    assert {:ok, _event} =
             Store.append(
               %{stream_id: unique("disabled-telemetry"), event_type: "task.created"},
               telemetry: false
             )

    multi =
      Store.append_multi(Ecto.Multi.new(), :event, %{
        stream_id: unique("multi-no-telemetry"),
        event_type: "task.created"
      })

    assert {:ok, %{event: {:inserted, event}}} = repo().transaction(multi)
    refute_receive {:event_telemetry, _, _, _}

    started_at = System.monotonic_time()
    Store.emit_result({:ok, {:inserted, event}}, started_at)

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :append],
                    %{duration: duration}, %{status: :inserted}}

    assert duration >= 0

    unsafe_event = %Event{
      stream_id: 123,
      event_type: <<255>>,
      project: %{secret: true},
      agent_id: nil,
      session_id: [:invalid],
      run_id: self(),
      payload: %{}
    }

    Store.emit_result({:ok, {:inserted, unsafe_event}}, started_at)

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], _, metadata}
    assert Map.drop(metadata, [:status]) |> Map.values() |> Enum.uniq() == [nil]
  end

  test "batch telemetry emits committed results and one error for a rolled-back batch" do
    attach_event_telemetry()
    stream_id = unique("batch-telemetry")
    duplicate_key = unique("batch-duplicate")
    duplicate_attrs = event(stream_id, "existing", duplicate_key)

    assert {:ok, _} = Store.append(duplicate_attrs, telemetry: false)

    assert {:ok, [_, duplicate]} =
             Store.append_batch([
               event(stream_id, "new"),
               duplicate_attrs
             ])

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :append], _,
                    %{status: :inserted}}

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :duplicate], measurements,
                    %{status: :duplicate}}

    assert measurements.content_bytes == byte_size(duplicate.content)
    refute_receive {:event_telemetry, _, _, _}

    rollback_stream = unique("batch-telemetry-rollback")

    assert {:error, :idempotency_conflict} =
             Store.append_batch([
               event(rollback_stream, "rolled back"),
               %{duplicate_attrs | content: "conflict"}
             ])

    assert_receive {:event_telemetry, [:backplane, :memory, :event, :error],
                    %{content_bytes: 0, payload_bytes: 0}, %{status: :error}}

    refute_receive {:event_telemetry, [:backplane, :memory, :event, :append], _, _}
    refute repo().get(Stream, rollback_stream)

    assert {:ok, [_]} =
             Store.append_batch([event(unique("batch-disabled"), "disabled")], telemetry: false)

    refute_receive {:event_telemetry, _, _, _}
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

  defp attach_event_telemetry do
    handler_id = "store-event-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    events =
      for outcome <- [:append, :duplicate, :error, :ingest],
          do: [:backplane, :memory, :event, outcome]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn name, measurements, metadata, _config ->
          send(parent, {:event_telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
