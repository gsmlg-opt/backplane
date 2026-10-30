ExUnit.start()
Code.require_file("support/openclaw_capture_barrier.exs", __DIR__)

defmodule Backplane.OpenClawCaptureBarrierTest do
  use ExUnit.Case, async: true
  alias Backplane.OpenClawCaptureBarrier

  test "chat terminal and admitted user messages do not settle a late assistant capture" do
    {turns, snapshot} = fixture()
    pending = put_in(snapshot, ["journal", "deliveries", Access.at(5), "state"], "local_pending")
    refute OpenClawCaptureBarrier.settled?(pending, turns)
    assert OpenClawCaptureBarrier.settled?(snapshot, turns)
  end

  test "empty assistant turns must complete their real agent_end hook" do
    {turns, snapshot} = fixture()
    pending = put_in(snapshot, ["journal", "turns", Access.at(3), "completed"], 0)
    refute OpenClawCaptureBarrier.settled?(pending, turns)
  end

  test "state labels alone cannot replace exact matching canonical acknowledgements" do
    {turns, snapshot} = fixture()

    for receipt <- [
          nil,
          "malformed",
          %{"event_id" => "other", "status" => "committed"},
          %{"event_id" => "event-0", "status" => "pending"}
        ] do
      invalid = put_in(snapshot, ["journal", "deliveries", Access.at(0), "receipt"], receipt)
      refute OpenClawCaptureBarrier.settled?(invalid, turns)
    end

    for id <- [nil, ""] do
      invalid =
        snapshot
        |> put_in(["journal", "deliveries", Access.at(0), "event_id"], id)
        |> put_in(["journal", "deliveries", Access.at(0), "receipt", "event_id"], id)

      refute OpenClawCaptureBarrier.settled?(invalid, turns)
    end
  end

  test "missing or substituted turn admission cannot produce an empty successful barrier" do
    {turns, snapshot} = fixture()
    refute OpenClawCaptureBarrier.settled?(%{}, turns)
    refute OpenClawCaptureBarrier.settled?(snapshot, [])
    refute OpenClawCaptureBarrier.settled?(snapshot, [hd(turns) | turns])

    for identity <- [nil, "not-json", "[\"other\"]"] do
      changed = put_in(snapshot, ["journal", "turns", Access.at(0), "identity"], identity)
      refute OpenClawCaptureBarrier.settled?(changed, turns)
    end

    missing_user = update_in(snapshot, ["journal", "deliveries"], &Enum.drop(&1, 1))
    refute OpenClawCaptureBarrier.settled?(missing_user, turns)
  end

  defp fixture do
    turns =
      for run <- 1..4,
          do: %{"agentId" => "main", "sessionId" => "session", "runId" => "run-#{run}"}

    completed =
      for turn <- turns,
          do: %{
            "identity" => Jason.encode!([turn["agentId"], turn["sessionId"], turn["runId"]]),
            "completed" => 1
          }

    deliveries =
      (Enum.map(turns, &{&1, "user"}) ++
         [{Enum.at(turns, 0), "assistant"}, {Enum.at(turns, 2), "assistant"}])
      |> Enum.with_index()
      |> Enum.map(fn {{turn, role}, index} ->
        id = "event-#{index}"

        %{
          "event_id" => id,
          "path" => "/capture/v1/hooks/openclaw/message",
          "state" => "canonical_committed",
          "receipt" => %{"event_id" => id, "status" => "committed"},
          "payload" => %{
            "agent_id" => turn["agentId"],
            "session_id" => turn["sessionId"],
            "run_id" => turn["runId"],
            "role" => role
          }
        }
      end)

    {turns, %{"journal" => %{"turns" => completed, "deliveries" => deliveries}}}
  end
end
