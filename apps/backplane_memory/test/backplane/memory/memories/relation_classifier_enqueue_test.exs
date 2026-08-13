defmodule Backplane.Memory.Memories.RelationClassifierEnqueueTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Workers.RelationClassifierWorker

  setup do
    keys = [
      "memory.pipeline.enabled",
      "memory.relation_classifier.enabled",
      "memory.embeddings.enabled"
    ]

    settings = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    previous_enqueue = Application.get_env(:backplane_memory, :relation_classifier_enqueue)

    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.relation_classifier.enabled", true})
    :ets.insert(:backplane_settings, {"memory.embeddings.enabled", false})

    on_exit(fn ->
      restore_env(:relation_classifier_enqueue, previous_enqueue)

      Enum.each(settings, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    :ok
  end

  test "new evidence revisions enqueue while exact idempotent request retries do not" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, memory} =
               Memories.remember("classifier enqueue",
                 agent_id: "agent",
                 host_id: "host",
                 idempotency_scope: "classifier-enqueue",
                 idempotency_key: "classifier-enqueue-1"
               )

      assert {:ok, ^memory} =
               Memories.remember("classifier enqueue",
                 agent_id: "agent",
                 host_id: "host",
                 idempotency_scope: "classifier-enqueue",
                 idempotency_key: "classifier-enqueue-2"
               )

      assert {:ok, ^memory} =
               Memories.remember("classifier enqueue",
                 agent_id: "agent",
                 host_id: "host",
                 idempotency_scope: "classifier-enqueue",
                 idempotency_key: "classifier-enqueue-2"
               )

      assert [first_job, second_job] =
               Oban.Testing.all_enqueued(repo(), worker: RelationClassifierWorker)

      assert first_job.args["memory_id"] == memory.id
      assert second_job.args["memory_id"] == memory.id
      assert first_job.args["processing_version"] == RelationClassifierWorker.processing_version()

      assert second_job.args["processing_version"] ==
               RelationClassifierWorker.processing_version()

      assert is_binary(first_job.args["evidence_revision"])
      assert is_binary(second_job.args["evidence_revision"])
      refute first_job.args["evidence_revision"] == second_job.args["evidence_revision"]
    end)
  end

  test "classifier enqueue failure is fail-open after a successful insert" do
    attach_enqueue_telemetry()
    owner = self()

    Application.put_env(:backplane_memory, :relation_classifier_enqueue, fn memory_id,
                                                                            _evidence_revision ->
      send(owner, {:enqueue_attempted, memory_id})
      {:error, :queue_down}
    end)

    assert {:ok, memory} =
             Memories.remember("classifier fail open", agent_id: "agent", host_id: "host")

    assert_received {:enqueue_attempted, memory_id}
    assert memory_id == memory.id
    assert {:ok, _persisted} = Memories.trusted_get(memory.id)

    assert_receive {:enqueue_telemetry, %{count: 1}, metadata}
    assert metadata == %{memory_id: memory.id, status: :error, reason_class: :queue_error}
    refute Map.has_key?(metadata, :content)
  end

  test "classifier enqueue exceptions are fail-open and emit content-free telemetry" do
    attach_enqueue_telemetry()

    Application.put_env(:backplane_memory, :relation_classifier_enqueue, fn _memory_id,
                                                                            _evidence_revision ->
      raise "secret memory content must not escape"
    end)

    assert {:ok, memory} =
             Memories.remember("classifier exception content", agent_id: "agent", host_id: "host")

    assert {:ok, _persisted} = Memories.trusted_get(memory.id)
    assert_receive {:enqueue_telemetry, %{count: 1}, metadata}
    assert metadata == %{memory_id: memory.id, status: :error, reason_class: :exception}
    refute inspect(metadata) =~ "secret memory content"
    refute inspect(metadata) =~ "classifier exception content"
  end

  test "only newly inserted semantic and procedural memories enqueue classification" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      memories =
        for type <- ~w(working episodic semantic procedural), into: %{} do
          assert {:ok, memory} =
                   Memories.remember("classifier type #{type}",
                     agent_id: "agent",
                     host_id: "host",
                     type: type
                   )

          {type, memory}
        end

      jobs = Oban.Testing.all_enqueued(repo(), worker: RelationClassifierWorker)

      assert MapSet.new(Enum.map(jobs, & &1.args["memory_id"])) ==
               MapSet.new([memories["semantic"].id, memories["procedural"].id])
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)

  defp attach_enqueue_telemetry do
    handler = "relation-classifier-enqueue-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :memory, :relation_classifier, :enqueue],
        fn _event, measurements, metadata, _config ->
          send(owner, {:enqueue_telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
