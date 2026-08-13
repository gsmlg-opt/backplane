defmodule Backplane.Memory.Operations.ProjectionRunnerTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Operations.ProjectionRunner
  alias Backplane.Memory.Projections.Source

  import Backplane.Memory.IngestFixtures

  test "dry-run is bounded, durable, and resumes from subject checkpoints" do
    session_a = unique("dry-a")
    session_b = unique("dry-b")
    ingest!("host-a", session_a)
    ingest!("host-b", session_b)
    assert {:ok, subjects} = Source.subjects()

    assert {:ok, first} =
             ProjectionRunner.run(
               run_id: "dry-run-1",
               dry_run: true,
               page_size: 1
             )

    assert first == %{
             run_id: "dry-run-1",
             status: "complete",
             scanned: length(subjects),
             rebuilt: 0,
             planned: length(subjects),
             skipped: 0,
             failed: 0,
             resumed: 0,
             limit_reached: false,
             failures: []
           }

    assert {:ok, resumed} =
             ProjectionRunner.run(
               run_id: "dry-run-1",
               dry_run: true,
               page_size: 1
             )

    assert resumed.resumed == length(subjects)
    assert resumed.planned == 0

    checkpoints = Audit.list(operation: "projection.rebuild.checkpoint", limit: 10)
    assert length(checkpoints) == length(subjects)
    assert Enum.all?(checkpoints, &(&1.metadata["status"] == "planned"))

    reports = Audit.list(operation: "projection.rebuild.report", limit: 10)
    assert length(reports) == 2
    assert Enum.all?(reports, &(&1.metadata["dry_run"] == true))
  end

  test "continue-on-error checkpoints failures and completes later subjects" do
    session_a = unique("failure-a")
    session_b = unique("failure-b")
    ingest!("host-a", session_a)
    ingest!("host-b", session_b)
    assert {:ok, subjects} = Source.subjects()

    rebuild = fn
      "host-a", ^session_a -> {:error, :injected}
      host_id, session_id -> {:ok, %{subject_id: "#{host_id}:#{session_id}"}}
    end

    assert {:error, report} =
             ProjectionRunner.run(
               run_id: "continue-1",
               continue_on_error: true,
               rebuild: rebuild
             )

    assert report.status == "partial"
    assert report.rebuilt == length(subjects) - 1
    assert report.failed == 1

    assert [%{host_id: "host-a", session_id: ^session_a, error_class: "injected"}] =
             report.failures

    statuses =
      Audit.list(operation: "projection.rebuild.checkpoint", limit: 10)
      |> Enum.map(& &1.metadata["status"])
      |> Enum.sort()

    assert Enum.count(statuses, &(&1 == "failed")) == 1
    assert Enum.count(statuses, &(&1 == "rebuilt")) == length(subjects) - 1
  end

  test "resume retries failed subjects but skips successfully rebuilt subjects" do
    session_a = unique("retry-a")
    session_b = unique("retry-b")
    ingest!("host-a", session_a)
    ingest!("host-b", session_b)
    assert {:ok, subjects} = Source.subjects()
    parent = self()

    first_rebuild = fn
      "host-a", ^session_a ->
        {:error, :temporary_provider_failure}

      host_id, session_id ->
        send(parent, {:rebuilt, host_id, session_id})
        {:ok, %{subject_id: "#{host_id}:#{session_id}"}}
    end

    assert {:error, %{failed: 1, rebuilt: rebuilt}} =
             ProjectionRunner.run(
               run_id: "retry-failed-1",
               continue_on_error: true,
               rebuild: first_rebuild
             )

    assert rebuilt == length(subjects) - 1

    assert_receive {:rebuilt, "host-b", ^session_b}

    retry_rebuild = fn host_id, session_id ->
      send(parent, {:retried, host_id, session_id})
      {:ok, %{subject_id: "#{host_id}:#{session_id}"}}
    end

    assert {:ok, %{rebuilt: 1, resumed: resumed, failed: 0}} =
             ProjectionRunner.run(run_id: "retry-failed-1", rebuild: retry_rebuild)

    assert resumed == length(subjects) - 1

    assert_receive {:retried, "host-a", ^session_a}
    refute_receive {:retried, "host-b", ^session_b}
  end

  test "a dry-run checkpoint never suppresses a later real rebuild with the same run id" do
    session = unique("planned-then-real")
    ingest!("host-a", session)
    assert {:ok, subjects} = Source.subjects()
    parent = self()

    assert {:ok, %{planned: planned}} =
             ProjectionRunner.run(run_id: "planned-then-real-1", dry_run: true)

    assert planned == length(subjects)

    rebuild = fn host_id, session_id ->
      send(parent, {:rebuilt_after_plan, host_id, session_id})
      {:ok, %{subject_id: "#{host_id}:#{session_id}"}}
    end

    assert {:ok, %{rebuilt: rebuilt, resumed: 0}} =
             ProjectionRunner.run(run_id: "planned-then-real-1", rebuild: rebuild)

    assert rebuilt == length(subjects)

    assert_receive {:rebuilt_after_plan, "host-a", ^session}
  end

  test "max_subjects bounds each invocation while the same run id advances through checkpoints" do
    ingest!("host-a", unique("bounded-a"))
    ingest!("host-b", unique("bounded-b"))
    assert {:ok, subjects} = Source.subjects()

    rebuild = fn host_id, session_id ->
      {:ok, %{subject_id: "#{host_id}:#{session_id}"}}
    end

    reports =
      Enum.map(1..length(subjects), fn _iteration ->
        assert {:ok, report} =
                 ProjectionRunner.run(
                   run_id: "bounded-resume-1",
                   max_subjects: 1,
                   rebuild: rebuild
                 )

        report
      end)

    assert Enum.all?(reports, &(&1.rebuilt == 1))
    assert Enum.map(reports, & &1.resumed) == Enum.to_list(0..(length(subjects) - 1))
    assert Enum.all?(Enum.drop(reports, -1), &(&1.status == "partial" and &1.limit_reached))
    assert %{status: "complete", limit_reached: false} = List.last(reports)
  end

  defp ingest!(host_id, session_id) do
    event =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => host_id,
        "session_id" => session_id,
        "idempotency_key" => "#{host_id}:#{session_id}:1"
      })

    auth = %{host_id: host_id, auth_token_id: "token-#{host_id}", scopes: ["host_agent.capture"]}

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(auth, %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => host_id,
               "events" => [event]
             })
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
