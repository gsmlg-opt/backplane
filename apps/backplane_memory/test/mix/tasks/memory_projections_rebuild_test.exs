defmodule Mix.Tasks.Memory.Projections.RebuildTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Projections.Source

  import Backplane.Memory.IngestFixtures
  import ExUnit.CaptureIO

  setup do
    on_exit(fn -> Mix.Task.reenable("memory.projections.rebuild") end)
    :ok
  end

  test "runs a targeted production read-model rebuild" do
    session_id = unique("target-task")
    ingest!(captured_event("host-task", session_id))

    output =
      capture_io(fn ->
        run_task(["--host", "host-task", "--session", session_id])
      end)

    assert output =~ "production read models"
    refute output =~ "validation-only"
    assert output =~ "host=host-task"
    assert output =~ "session=#{session_id}"
    assert output =~ "gaps=none"
    assert output =~ "observations:complete"

    assert [%{actor: "mix:memory.projections.rebuild", metadata: metadata}] =
             Audit.list(operation: "projection.rebuild", limit: 1)

    assert metadata["host_id"] == "host-task"
    assert metadata["client_id"] == "host:host-task"
    assert metadata["scope"] == "project:backplane"
    assert metadata["namespace"] == "private"
    assert metadata["result"] == "rebuilt"
    assert is_binary(metadata["request_id"])
    assert metadata["correlation_ids"] == ["correlation-1"]

    run_task(["--host", "host-task", "--session", session_id])
    assert length(Audit.list(operation: "projection.rebuild")) == 1
  end

  test "runs a full rebuild in stable subject order" do
    session_a = unique("all-task-a")
    session_b = unique("all-task-b")
    ingest!(captured_event("host-z", session_b))
    ingest!(captured_event("host-a", session_a))
    assert {:ok, expected_subjects} = Source.subjects()

    output = capture_io(fn -> run_task([]) end)

    assert output =~ "production read models"
    refute output =~ "validation-only"
    assert output =~ "rebuilt=#{length(expected_subjects)}"
    assert output =~ "session=#{session_a}"
    assert output =~ "session=#{session_b}"
    assert index_of(output, session_a) < index_of(output, session_b)
  end

  test "supports resumable dry-run and bounded runner options" do
    session_id = unique("runner-options")
    ingest!(captured_event("host-runner", session_id))

    output =
      capture_io(fn ->
        run_task([
          "--dry-run",
          "--continue-on-error",
          "--failed-only",
          "--page-size",
          "1",
          "--max-subjects",
          "1",
          "--run-id",
          "task-dry-run"
        ])
      end)

    assert output =~ "run_id=task-dry-run"
    assert output =~ "status="
    assert output =~ "planned=0"
    assert output =~ "skipped="
    assert output =~ "limit_reached="

    assert [%{metadata: %{"run_id" => "task-dry-run", "dry_run" => true}} | _] =
             Audit.list(operation: "projection.rebuild.report", limit: 10)
  end

  test "rejects partial, unknown, positional, and duplicate arguments with usage" do
    for args <- [
          ["--host", "host-only"],
          ["--session", "session-only"],
          ["--unknown", "value"],
          ["--page-size", "0"],
          ["--max-subjects", "0"],
          ["--run-id", ""],
          ["positional"],
          ["--host", "one", "--host", "two", "--session", "session"]
        ] do
      assert_raise Mix.Error, ~r/Usage: mix memory\.projections\.rebuild/, fn ->
        run_task(args)
      end
    end
  end

  defp run_task(args) do
    Mix.Task.reenable("memory.projections.rebuild")
    Mix.Tasks.Memory.Projections.Rebuild.run(args)
  end

  defp captured_event(host_id, session_id) do
    valid_event(%{
      "event_id" => Ecto.UUID.generate(),
      "host_id" => host_id,
      "session_id" => session_id,
      "idempotency_key" => "#{host_id}:#{session_id}:1"
    })
  end

  defp ingest!(event) do
    auth = %{
      host_id: event["host_id"],
      auth_token_id: "token-#{event["host_id"]}",
      scopes: ["host_agent.capture"]
    }

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => event["host_id"],
               "events" => [event]
             })
  end

  defp index_of(output, value) do
    {index, _length} = :binary.match(output, value)
    index
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
