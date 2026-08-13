defmodule Backplane.Memory.Recall.PurgeWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Audit
  alias Backplane.Memory.Recall.{Candidate, QueryPlan, Run, Store, TraceCandidate}
  alias Backplane.Memory.Workers.RecallTracePurgeWorker

  @partition %{host_id: "host-a", client_id: "client-a", scope: "team", namespace: "private"}

  test "bounded concurrent purges delete only expired runs, cascade, audit, and emit telemetry" do
    attach_telemetry()

    expired = for index <- 1..3, do: create_run("expired-#{index}", true)
    active = create_run("active", false)

    results =
      1..3
      |> Task.async_stream(fn _ -> RecallTracePurgeWorker.perform(%Oban.Job{}) end,
        max_concurrency: 3,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, %{deleted: count}}} -> count end)

    assert Enum.sum(results) == 3
    assert repo().aggregate(Run, :count) == 1
    assert repo().get!(Run, active.id)
    assert repo().aggregate(TraceCandidate, :count) == 1

    audits = Audit.list(operation: "memory.recall_trace.purge")
    assert Enum.sum(Enum.map(audits, & &1.metadata["count"])) == 3

    assert Enum.sort(Enum.flat_map(audits, & &1.target_ids)) ==
             Enum.sort(Enum.map(expired, & &1.id))

    assert_receive {:purge_telemetry, %{deleted: deleted}, %{status: :ok}}
    assert deleted in 0..3

    assert {:ok, %{deleted: 0}} = RecallTracePurgeWorker.perform(%Oban.Job{})
    assert length(Audit.list(operation: "memory.recall_trace.purge")) == length(audits)
  end

  test "one purge invocation is capped at one hundred runs" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for index <- 1..101 do
        %{
          id: Ecto.UUID.generate(),
          host_id: "host-a",
          client_id: "client-a",
          scope: "team",
          namespace: "private",
          request_id: "bounded-#{index}",
          correlation_id: "c",
          query_hash: :crypto.hash(:sha256, "query-#{index}"),
          normalized_query: nil,
          query_plan: %{},
          filters: %{},
          channel_weights: %{},
          channel_availability: %{},
          channel_errors: %{},
          token_budget: 100,
          tokens_used: 0,
          result_count: 0,
          status: "running",
          expires_at: DateTime.add(now, -1, :day),
          inserted_at: DateTime.add(now, -31, :day),
          updated_at: now
        }
      end

    assert {101, nil} = repo().insert_all(Run, rows)
    assert {:ok, %{deleted: 100}} = RecallTracePurgeWorker.perform(%Oban.Job{})
    assert repo().aggregate(Run, :count) == 1
    assert {:ok, %{deleted: 1}} = RecallTracePurgeWorker.perform(%Oban.Job{})
  end

  defp create_run(label, expired?) do
    {:ok, plan} = QueryPlan.new(Map.put(@partition, :query, label))
    source_id = Ecto.UUID.generate()

    {:ok, run} =
      Store.create(plan,
        request_id: "#{label}-#{System.unique_integer([:positive])}",
        correlation_id: "c"
      )

    {:ok, candidate} =
      Candidate.new(
        Map.merge(@partition, %{
          id: Ecto.UUID.generate(),
          kind: :memory,
          memory_type: :semantic,
          content: label,
          source_ids: [source_id],
          source_refs: [%{type: :event, id: source_id}]
        })
      )

    {:ok, _} =
      Store.put_candidates(run.id, @partition, [
        %{
          candidate: candidate,
          selected: false,
          rejection_reason: "review",
          scores: %{final: 0.1}
        }
      ])

    if expired? do
      repo().update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          inserted_at: DateTime.add(DateTime.utc_now(), -31, :day),
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        ]
      )
    end

    run
  end

  defp attach_telemetry do
    owner = self()
    handler = "recall-purge-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :memory, :recall_trace, :purge],
        fn _name, measurements, metadata, _config ->
          send(owner, {:purge_telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
