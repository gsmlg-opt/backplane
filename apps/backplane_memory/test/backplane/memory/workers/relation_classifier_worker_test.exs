defmodule Backplane.Memory.Workers.RelationClassifierWorkerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Relations
  alias Backplane.Memory.Workers.RelationClassifierWorker

  defmodule ExplodingLLM do
    def classify_relation(_source, _target), do: flunk("disabled classifier called the LLM")
  end

  defmodule ScriptedLLM do
    def classify_relation(_source, _target), do: Process.get(:classifier_result)
  end

  setup do
    keys = [
      "memory.pipeline.enabled",
      "memory.relation_classifier.enabled",
      "memory.llm_model"
    ]

    settings = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    previous_llm = Application.get_env(:backplane_memory, :llm_module)

    Application.put_env(:backplane_memory, :llm_module, ExplodingLLM)
    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", false})
    :ets.insert(:backplane_settings, {"memory.relation_classifier.enabled", true})
    :ets.insert(:backplane_settings, {"memory.llm_model", "test-model"})

    on_exit(fn ->
      restore_env(:llm_module, previous_llm)

      Enum.each(settings, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    :ok
  end

  test "disabled classifier skips without loading or invoking the model" do
    {:ok, memory} = Memories.remember("disabled classifier", agent_id: "agent", host_id: "host")

    assert :ok = perform(memory.id)
  end

  test "worker uses a dedicated serial queue and revision-stable uniqueness" do
    opts = RelationClassifierWorker.__opts__()

    assert opts[:queue] == :memory_relation_classifier
    assert opts[:max_attempts] == 3
    assert Application.fetch_env!(:backplane, Oban)[:queues][:memory_relation_classifier] == 1
    assert opts[:unique][:period] == :infinity
    assert opts[:unique][:states] == :incomplete

    assert opts[:unique][:keys] == [
             :memory_id,
             :processing_version,
             :evidence_revision
           ]
  end

  test "a disabled completed revision can be enqueued again after re-enable" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, memory} =
        Memories.remember("re-enable classifier", agent_id: "agent", host_id: "host")

      revision = "same-evidence-revision"
      assert {:ok, first_job} = RelationClassifierWorker.enqueue(memory.id, revision)
      assert :ok = perform(memory.id)

      first_job
      |> Ecto.Changeset.change(
        state: "completed",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      |> repo().update!()

      enable_classifier()
      assert {:ok, second_job} = RelationClassifierWorker.enqueue(memory.id, revision)
      refute second_job.conflict?
      refute second_job.id == first_job.id
    end)
  end

  test "enabled classifier skips a missing memory" do
    enable_classifier()
    assert :ok = perform(Ecto.UUID.generate())
  end

  test "enabled classifier skips a deleted memory" do
    {:ok, memory} = Memories.remember("deleted classifier", agent_id: "agent", host_id: "host")
    assert :ok = Memories.trusted_forget(memory.id)
    enable_classifier()

    assert :ok = perform(memory.id)
  end

  test "enabled classifier skips ambiguous work when no model is configured" do
    {:ok, memory} = Memories.remember("no classifier model", agent_id: "agent", host_id: "host")
    :ets.delete(:backplane_settings, "memory.llm_model")
    enable_classifier()

    assert :ok = perform(memory.id)
  end

  test "transient model failures return an error for Oban retry" do
    {_first, second} = ambiguous_pair()
    Application.put_env(:backplane_memory, :llm_module, ScriptedLLM)
    Process.put(:classifier_result, {:error, :provider_down})
    enable_classifier()

    assert {:error, :provider_down} = perform(second.id)
  end

  test "malformed model output retries without creating a relation" do
    {first, second} = ambiguous_pair()
    Application.put_env(:backplane_memory, :llm_module, ScriptedLLM)
    Process.put(:classifier_result, {:ok, %{"classification" => "extension"}})
    enable_classifier()

    assert {:error, :invalid_classifier_response} = perform(second.id)
    assert Relations.list_relations(first.id) == []
  end

  defp perform(memory_id) do
    RelationClassifierWorker.perform(%Oban.Job{
      args: %{
        "memory_id" => memory_id,
        "processing_version" => RelationClassifierWorker.processing_version(),
        "evidence_revision" => "test-evidence-revision"
      }
    })
  end

  defp enable_classifier do
    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.relation_classifier.enabled", true})
  end

  defp ambiguous_pair do
    {:ok, first} =
      Memories.remember("first ambiguous memory",
        agent_id: "agent",
        host_id: "host",
        metadata: %{"entities" => ["backplane"]}
      )

    {:ok, second} =
      Memories.remember("second ambiguous memory",
        agent_id: "agent",
        host_id: "host",
        metadata: %{"entities" => ["backplane"]}
      )

    {first, second}
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_memory, key, value)
end
