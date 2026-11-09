defmodule Backplane.Memory.DistillationsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Distillation, Distillations, Records}
  alias Backplane.Memory.Ingest
  alias Backplane.Memory.Projections.{Rebuild, Source}

  import Backplane.Memory.IngestFixtures

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp ingest!(host, session, seq, type) do
    event =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => host,
        "session_id" => session,
        "sequence" => seq,
        "event_type" => type,
        "occurred_at" => "2026-08-04T01:0#{seq}:00.000Z",
        "idempotency_key" => "#{host}:#{session}:#{seq}:#{type}"
      })

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(ingest_auth_context(host), %{
               "batch_id" => Ecto.UUID.generate(),
               "host_id" => host,
               "events" => [event]
             })
  end

  defp row(host, session), do: repo().get(Distillation, Source.subject_id!(host, session))

  defp insert_row(attrs) do
    now = DateTime.utc_now()

    struct!(
      Distillation,
      Map.merge(
        %{
          subject_id: unique("subj"),
          status: "pending",
          mode: "distill",
          due_at: now,
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
    |> repo().insert!()
  end

  describe "session-close trigger" do
    test "ending a session creates a pending row due after the delay" do
      s = unique("close")
      ingest!("host-d", s, 1, "agent.session.started")
      Rebuild.session("host-d", s)
      assert row("host-d", s) == nil

      before = DateTime.utc_now()
      ingest!("host-d", s, 2, "agent.session.ended")
      assert {:ok, _} = Rebuild.session("host-d", s)

      r = row("host-d", s)
      assert r.status == "pending"
      assert r.mode == "distill"
      assert r.host_id == "host-d" and r.session_id == s
      assert_in_delta DateTime.diff(r.due_at, before), 600, 5
    end

    test "stopped transition creates no row" do
      s = unique("stop")
      ingest!("host-d", s, 1, "agent.session.started")
      ingest!("host-d", s, 2, "agent.session.stopped")
      assert {:ok, %{session_status: "stopped"}} = Rebuild.session("host-d", s)
      assert row("host-d", s) == nil
    end

    test "reopening and closing again resets the row to pending" do
      s = unique("reopen")
      ingest!("host-d", s, 1, "agent.session.started")
      ingest!("host-d", s, 2, "agent.session.ended")
      Rebuild.session("host-d", s)
      id = Source.subject_id!("host-d", s)
      :ok = Distillations.complete(id, 3)
      assert row("host-d", s).status == "completed"

      ingest!("host-d", s, 3, "agent.session.started")
      Rebuild.session("host-d", s)
      assert row("host-d", s).status == "completed"

      ingest!("host-d", s, 4, "agent.session.ended")
      Rebuild.session("host-d", s)
      assert row("host-d", s).status == "pending"
    end

    test "mode is review when the agent self-wrote records for the session" do
      s = unique("review")
      {:ok, _} =
        Records.remember(%{
          "kind" => "note",
          "content" => "self note",
          "writer" => "agent",
          "host_id" => "host-d",
          "session_id" => s
        })

      ingest!("host-d", s, 1, "agent.session.started")
      ingest!("host-d", s, 2, "agent.session.ended")
      Rebuild.session("host-d", s)
      assert row("host-d", s).mode == "review"
    end
  end

  describe "state machine" do
    test "claim_due respects limit, skips future rows, increments attempts" do
      now = DateTime.utc_now()
      a = insert_row(%{due_at: DateTime.add(now, -20)})
      b = insert_row(%{due_at: DateTime.add(now, -10)})
      f = insert_row(%{due_at: DateTime.add(now, 3600)})

      assert [claimed] = Distillations.claim_due(now, 1)
      assert claimed.subject_id == a.subject_id
      assert claimed.status == "running"
      assert claimed.attempts == 1
      assert claimed.started_at

      assert [second] = Distillations.claim_due(now, 5)
      assert second.subject_id == b.subject_id
      assert repo().get(Distillation, f.subject_id).status == "pending"
      assert Distillations.running_count() == 2
    end

    test "claim_due recomputes mode" do
      s = unique("mode")
      r = insert_row(%{host_id: "h", session_id: s})

      {:ok, _} =
        Records.remember(%{
          "kind" => "note",
          "content" => "x",
          "writer" => "agent",
          "host_id" => "h",
          "session_id" => s
        })

      assert [%{mode: "review"}] = Distillations.claim_due(DateTime.utc_now(), 1)
      assert repo().get(Distillation, r.subject_id).mode == "review"
    end

    test "schedule leaves running rows untouched" do
      r = insert_row(%{status: "running", mode: "distill"})

      assert {:ok, %{status: "running"}} =
               Distillations.schedule(%{
                 subject_id: r.subject_id,
                 host_id: "h",
                 session_id: "s",
                 agent_id: nil,
                 integration: nil
               })
    end

    test "block_due then unblock_all round-trips" do
      now = DateTime.utc_now()
      a = insert_row(%{due_at: DateTime.add(now, -5)})
      f = insert_row(%{due_at: DateTime.add(now, 500)})

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert Distillations.block_due(now, "memory.llm_model not configured") == 1
             end) =~ "memory.llm_model not configured"

      blocked = repo().get(Distillation, a.subject_id)
      assert blocked.status == "blocked"
      assert blocked.last_error == "memory.llm_model not configured"
      assert repo().get(Distillation, f.subject_id).status == "pending"

      assert Distillations.unblock_all() == 1
      assert repo().get(Distillation, a.subject_id).status == "pending"
      assert Distillations.counts()["pending"] == 2
    end

    test "fail logs and stores the reason; complete stores count" do
      a = insert_row(%{status: "running"})

      assert ExUnit.CaptureLog.capture_log(fn -> Distillations.fail(a.subject_id, "boom") end) =~
               "boom"

      assert %{status: "failed", last_error: "boom"} = repo().get(Distillation, a.subject_id)

      :ok = Distillations.complete(a.subject_id, 4)
      assert %{status: "completed", records_written: 4} = repo().get(Distillation, a.subject_id)
      assert %{} = Distillations.for_subjects([a.subject_id])
    end

    test "reset_stale_running and retry" do
      now = DateTime.utc_now()
      a = insert_row(%{status: "running", started_at: DateTime.add(now, -7200)})
      fresh = insert_row(%{status: "running", started_at: now})

      assert Distillations.reset_stale_running(DateTime.add(now, -3600)) == 1
      assert repo().get(Distillation, a.subject_id).status == "pending"
      assert repo().get(Distillation, fresh.subject_id).status == "running"

      f = insert_row(%{status: "failed", last_error: "x"})
      assert {:ok, %{status: "pending", last_error: nil}} = Distillations.retry(f.subject_id)
      assert {:error, :not_found} = Distillations.retry("missing")
      assert {:error, :not_found} = Distillations.retry(fresh.subject_id)
    end
  end
end
