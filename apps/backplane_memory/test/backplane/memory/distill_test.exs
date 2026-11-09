defmodule Backplane.Memory.DistillTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Distillation, Distillations}
  alias Backplane.Memory.Distill
  alias Backplane.Memory.Projections.ProjectedObservation

  defmodule FakeProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, _context) do
      send(Application.fetch_env!(:backplane_memory, :distill_test_pid), {:provider_request, request})
      [%{type: :response_started}, %{type: :response_failed, error: "boom from provider"}]
    end
  end

  defmodule OkProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(_request, _context) do
      [
        %{type: :response_started},
        %{type: :response_completed, message: %{role: :assistant, content: "Done."}}
      ]
    end
  end

  setup do
    previous = Application.get_env(:backplane_memory, :distill_provider)
    on_exit(fn -> restore(:distill_provider, previous) end)
    Application.put_env(:backplane_memory, :distill_test_pid, self())
    on_exit(fn -> Application.delete_env(:backplane_memory, :distill_test_pid) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:backplane_memory, key)
  defp restore(key, value), do: Application.put_env(:backplane_memory, key, value)

  defp insert_row(subject_id) do
    now = DateTime.utc_now()

    repo().insert!(%Distillation{
      subject_id: subject_id,
      host_id: "host-d",
      session_id: "sess-#{subject_id}",
      agent_id: "claude",
      integration: "claude_code",
      status: "running",
      mode: "distill",
      due_at: now,
      inserted_at: now,
      updated_at: now
    })
  end

  defp insert_observation(subject_id, seq) do
    now = DateTime.utc_now()

    repo().insert!(%ProjectedObservation{
      event_id: Ecto.UUID.generate(),
      subject_id: subject_id,
      host_id: "host-d",
      session_id: "sess-#{subject_id}",
      source_sequence: seq,
      event_type: "tool_use",
      occurred_at: now,
      content: "content #{seq}",
      processing_version: "v1",
      input_revision: "r1",
      inserted_at: now,
      updated_at: now
    })
  end

  defp row(id), do: repo().get!(Distillation, id)

  test "an empty session completes with zero records and no provider call" do
    Application.put_env(:backplane_memory, :distill_provider, FakeProvider)
    insert_row("empty")

    assert :ok = Distill.run("empty")

    assert %{status: "completed", records_written: 0} = row("empty")
    refute_received {:provider_request, _}
  end

  test "a successful run completes the row" do
    Application.put_env(:backplane_memory, :distill_provider, OkProvider)
    insert_row("ok")
    insert_observation("ok", 1)

    assert :ok = Distill.run("ok")
    assert %{status: "completed", records_written: 0, last_error: nil} = row("ok")
  end

  test "a failing provider fails the row with chunk and reason" do
    Application.put_env(:backplane_memory, :distill_provider, FakeProvider)
    insert_row("bad")
    insert_observation("bad", 1)

    ExUnit.CaptureLog.capture_log(fn -> assert :ok = Distill.run("bad") end)

    assert %{status: "failed", last_error: "chunk 1/1: " <> rest} = row("bad")
    assert rest =~ "boom from provider"
    assert Distillations.counts()["failed"] == 1
  end

  test "an unknown subject is a no-op" do
    assert :ok = Distill.run("missing")
  end
end
