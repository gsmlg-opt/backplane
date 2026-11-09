defmodule Backplane.Memory.Workers.DistillSchedulerWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import ExUnit.CaptureLog

  alias Backplane.Memory.{Distillation, Distillations}
  alias Backplane.Memory.Projections.ProjectedObservation
  alias Backplane.Memory.Workers.DistillSchedulerWorker

  @settings_table :backplane_settings
  @keys ["memory.llm_model", "memory.distill_max_concurrency"]

  # Reads the chunk once, then finishes without writing.
  defmodule OkProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, _context) do
      if Enum.any?(request.messages, &(&1[:role] == :tool)) do
        [
          %{type: :response_started},
          %{type: :response_completed, message: %{role: :assistant, content: "Done."}}
        ]
      else
        call = %{id: "c0", name: "read_chunk", arguments: %{}}

        [
          %{type: :response_started},
          %{type: :tool_call_completed, tool_call: call},
          %{
            type: :response_completed,
            message: %{role: :assistant, content: [Map.put(call, :type, :tool_call)]}
          }
        ]
      end
    end
  end

  defmodule FailProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(_request, _context) do
      [%{type: :response_started}, %{type: :response_failed, error: "HTTP 400 for model m"}]
    end
  end

  defmodule RaisingProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(_request, _context), do: raise("provider exploded")
  end

  setup do
    snapshot = Map.new(@keys, &{&1, :ets.lookup(@settings_table, &1)})
    previous = Application.get_env(:backplane_memory, :distill_provider)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {key, []} -> :ets.delete(@settings_table, key)
        {_key, [row]} -> :ets.insert(@settings_table, row)
      end)

      if previous,
        do: Application.put_env(:backplane_memory, :distill_provider, previous),
        else: Application.delete_env(:backplane_memory, :distill_provider)
    end)

    :ets.delete(@settings_table, "memory.llm_model")
    :ets.delete(@settings_table, "memory.distill_max_concurrency")
    :ok
  end

  defp set_model, do: :ets.insert(@settings_table, {"memory.llm_model", "test-model"})

  defp pending(id, due_offset \\ -60, with_observation \\ true) do
    now = DateTime.utc_now()

    repo().insert!(%Distillation{
      subject_id: id,
      host_id: "host-s",
      session_id: "sess-#{id}",
      agent_id: "claude",
      integration: "claude_code",
      status: "pending",
      mode: "distill",
      due_at: DateTime.add(now, due_offset, :second),
      inserted_at: now,
      updated_at: now
    })

    if with_observation do
      repo().insert!(%ProjectedObservation{
        event_id: Ecto.UUID.generate(),
        subject_id: id,
        host_id: "host-s",
        session_id: "sess-#{id}",
        source_sequence: 1,
        event_type: "tool_use",
        occurred_at: now,
        content: "did a thing",
        processing_version: "v1",
        input_revision: "r1",
        inserted_at: now,
        updated_at: now
      })
    end
  end

  defp row(id), do: repo().get!(Distillation, id)
  defp run_scheduler, do: DistillSchedulerWorker.perform(%Styx.Job{args: %{}})

  test "without a model due rows are blocked and future rows stay pending" do
    pending("due")
    pending("future", 3600)

    log = capture_log(fn -> assert :ok = run_scheduler() end)

    assert %{status: "blocked", last_error: "memory.llm_model not configured"} = row("due")
    assert %{status: "pending"} = row("future")
    assert log =~ "memory.llm_model not configured"
  end

  test "with a model it runs due rows to completion and unblocks blocked rows" do
    Application.put_env(:backplane_memory, :distill_provider, OkProvider)
    pending("a")
    pending("future", 3600)
    capture_log(fn -> run_scheduler() end)
    assert %{status: "blocked"} = row("a")

    set_model()
    assert :ok = run_scheduler()

    assert %{status: "completed", records_written: 0, attempts: 1} = row("a")
    assert %{status: "pending"} = row("future")
  end

  test "claims at most the concurrency limit" do
    Application.put_env(:backplane_memory, :distill_provider, OkProvider)
    set_model()
    :ets.insert(@settings_table, {"memory.distill_max_concurrency", 1})
    pending("one")
    pending("two")

    assert :ok = run_scheduler()

    statuses = Distillations.counts()
    assert statuses["completed"] == 1
    assert statuses["pending"] == 1
  end

  test "a failing provider ends failed with the reason" do
    Application.put_env(:backplane_memory, :distill_provider, FailProvider)
    set_model()
    pending("bad")

    capture_log(fn -> assert :ok = run_scheduler() end)

    assert %{status: "failed", last_error: error} = row("bad")
    assert error =~ "HTTP 400 for model m"
  end

  test "an empty session completes with zero records" do
    Application.put_env(:backplane_memory, :distill_provider, FailProvider)
    set_model()
    pending("empty", -60, false)

    assert :ok = run_scheduler()
    assert %{status: "completed", records_written: 0} = row("empty")
  end

  test "an exception inside the agent run becomes failed" do
    Application.put_env(:backplane_memory, :distill_provider, RaisingProvider)
    set_model()
    pending("boom")

    capture_log(fn -> assert :ok = run_scheduler() end)

    assert %{status: "failed", last_error: error} = row("boom")
    assert is_binary(error) and error != ""
  end
end
