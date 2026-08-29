defmodule Backplane.Memory.Eval.RunnerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Eval
  alias Backplane.Memory.Eval.Runner
  alias Backplane.Memory.Memories.Memory
  alias Backplane.Memory.Recall.Pipeline

  setup do
    previous = Application.get_env(:backplane_memory, :recall_task_supervisor)
    supervisor = start_supervised!({Task.Supervisor, name: unique_supervisor()})
    Application.put_env(:backplane_memory, :recall_task_supervisor, supervisor)

    on_exit(fn ->
      if is_pid(previous) do
        Application.put_env(
          :backplane_memory,
          :recall_task_supervisor,
          Backplane.Memory.Recall.TaskSupervisor
        )
      else
        if previous,
          do: Application.put_env(:backplane_memory, :recall_task_supervisor, previous),
          else: Application.delete_env(:backplane_memory, :recall_task_supervisor)
      end
    end)

    :ok
  end

  test "runs every M15 gate through Recall Pipeline inside the rollback sandbox" do
    assert {:ok, fixture} = Eval.load_fixture()
    assert {:error, :insufficient_warmups} = Runner.evaluate(fixture, warmups: 4, samples: 100)
    assert {:ok, report, export} = Runner.run(warmups: 5, samples: 100, profile: :ci)

    assert report.profile == :ci
    refute report.performance_authoritative
    assert report.effective_thresholds.retrieval_fusion_p95_ms_max_exclusive == 3_000.0
    assert report.effective_thresholds.e2e_p95_ms_max_exclusive == 8_000.0
    assert report.quality.queries == 20
    assert report.quality.recall_any_at_5 >= 0.95

    assert report.outage.mode == "FTS-only; embedder and LLM unavailable"
    assert report.outage.samples == 100
    assert report.outage.availability == 1.0

    assert report.provenance == %{coverage: 1.0, denominator: 2, numerator: 2, persisted: 2}
    assert report.outage.embedding_provider_calls > 0
    assert report.outage.reranker_provider_calls > 0
    assert report.outage.nonempty_fts_results == report.outage.samples
    assert report.latency.retrieval_fusion.samples == 100
    assert report.latency.e2e.samples == 100
    assert report.configuration.measured_sample_count == 100
    assert report.configuration.sample_semantics =~ "not samples per query"
    assert report.passed
    assert Enum.all?(report.thresholds, fn {_gate, passed} -> passed end)
    assert Eval.thresholds_pass?(report, profile: :ci)
    assert export.sidecar["directly_comparable"] == false
    assert export.sidecar["evaluation_mode"] == "retrieval-only"

    fixture_id = fixture["fixture_id"]

    assert repo().exists?(
             from(memory in Memory,
               where: fragment("?->>'fixture_id'", memory.metadata) == ^fixture_id
             )
           )
  end

  test "counts every expected derived fixture when retrieval omits its persisted summary" do
    pipeline = fn attrs, opts ->
      if attrs["project"] == "memory-eval-derived" do
        {:ok, %{results: []}}
      else
        Pipeline.run(attrs, opts)
      end
    end

    assert {:ok, report, _export} = Runner.run(warmups: 5, samples: 100, pipeline: pipeline)
    assert report.provenance == %{coverage: 0.0, denominator: 2, numerator: 0, persisted: 2}
    refute report.thresholds.derived_provenance
    refute report.passed
  end

  defp unique_supervisor,
    do: String.to_atom("eval-recall-#{System.unique_integer([:positive])}")
end
