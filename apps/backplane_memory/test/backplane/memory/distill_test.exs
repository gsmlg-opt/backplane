defmodule Backplane.Memory.DistillTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query, only: [from: 2]

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

  # Replies with text only and never calls a tool.
  defmodule TextOnlyProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(_request, _context) do
      [
        %{type: :response_started},
        %{type: :response_completed, message: %{role: :assistant, content: "Done."}}
      ]
    end
  end

  # Stateless scripted model: reads the chunk, reports it to the test, then fails the
  # chunk if an observation starts with "boom", writes a worklog for an observation
  # containing "write", or finishes.
  defmodule ChunkProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, _context) do
      pid = Application.fetch_env!(:backplane_memory, :distill_test_pid)

      case Enum.filter(request.messages, &(&1[:role] == :tool)) do
        [] ->
          call("c0", "read_chunk", %{})

        [read] ->
          %{"observations" => observations} = body = Jason.decode!(read.result.content)
          send(pid, {:chunk_read, body})
          act(observations)

        _ ->
          text()
      end
    end

    defp act(observations) do
      cond do
        Enum.any?(observations, &String.starts_with?(&1["content"], "boom")) ->
          [%{type: :response_started}, %{type: :response_failed, error: "boom from provider"}]

        obs = Enum.find(observations, &String.contains?(&1["content"], "write")) ->
          call("c1", "write_memory", %{
            "kind" => "worklog",
            "content" => "worked on " <> obs["event_id"],
            "source_event_ids" => [obs["event_id"]]
          })

        true ->
          text()
      end
    end

    defp call(id, name, arguments) do
      call = %{id: id, name: name, arguments: arguments}

      [
        %{type: :response_started},
        %{type: :tool_call_completed, tool_call: call},
        %{
          type: :response_completed,
          message: %{role: :assistant, content: [Map.put(call, :type, :tool_call)]}
        }
      ]
    end

    defp text do
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

  defp insert_observation(subject_id, seq, content \\ nil) do
    now = DateTime.utc_now()

    repo().insert!(%ProjectedObservation{
      event_id: Ecto.UUID.generate(),
      subject_id: subject_id,
      host_id: "host-d",
      session_id: "sess-#{subject_id}",
      source_sequence: seq,
      event_type: "tool_use",
      occurred_at: now,
      content: content || "content #{seq}",
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

  defp reads do
    receive do
      {:chunk_read, body} -> [body | reads()]
    after
      0 -> []
    end
  end

  defp read_event_ids,
    do: reads() |> Enum.flat_map(& &1["observations"]) |> Enum.map(& &1["event_id"])

  test "a successful run completes the row" do
    Application.put_env(:backplane_memory, :distill_provider, ChunkProvider)
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

  describe "tool input (finding 1)" do
    import Backplane.Memory.IngestFixtures

    alias Backplane.Memory.Ingest
    alias Backplane.Memory.Projections.{Rebuild, Source}

    test "a PostToolUse event's tool_input.command reaches read_chunk" do
      Application.put_env(:backplane_memory, :distill_provider, ChunkProvider)
      host = "host-ti"
      session = "sess-ti-#{System.unique_integer([:positive])}"

      payload = %{
        "hook" => "post-tool-use",
        "source" => %{
          "session_id" => session,
          "tool_name" => "Bash",
          "tool_input" => %{"command" => "cd /srv/backplane && mix ecto.migrate"},
          "tool_response" => %{"stdout" => "migrated"}
        }
      }

      event =
        valid_event(%{
          "host_id" => host,
          "session_id" => session,
          "sequence" => 1,
          "event_type" => "agent.tool.completed",
          "idempotency_key" => "#{host}:#{session}:1",
          "payload" => payload
        })

      assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
               Ingest.ingest_batch(ingest_auth_context(host), %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => host,
                 "events" => [event]
               })

      assert {:ok, _} = Rebuild.session(host, session)
      subject_id = Source.subject_id!(host, session)
      insert_row(subject_id)

      assert :ok = Distill.run(subject_id)
      assert %{status: "completed"} = row(subject_id)

      assert [%{"observations" => [observation]}] = reads()
      assert observation["input"] =~ "cd /srv/backplane && mix ecto.migrate"
    end
  end

  describe "progress, heartbeat and chunk cap (findings 2 and 3)" do
    test "processes at most 20 chunks per run, then requeues and continues from the watermark" do
      Application.put_env(:backplane_memory, :distill_provider, ChunkProvider)
      insert_row("big")
      # ~4 KB each: five observations per 24 KB chunk, so 105 observations make 21 chunks.
      for seq <- 1..105, do: insert_observation("big", seq, String.duplicate("x", 4_000))

      assert :ok = Distill.run("big")

      first = row("big")
      assert first.status == "pending"
      assert first.distilled_through_sequence == 100
      assert first.heartbeat_at
      assert length(reads()) == 20

      assert :ok = Distill.run("big")
      assert %{status: "completed", distilled_through_sequence: 105} = row("big")
      assert length(reads()) == 1
    end

    test "a reopened session only distills observations after the watermark" do
      Application.put_env(:backplane_memory, :distill_provider, ChunkProvider)
      insert_row("reopen")
      a = insert_observation("reopen", 1, "write first")
      assert :ok = Distill.run("reopen")

      assert %{status: "completed", records_written: 1, distilled_through_sequence: 1} =
               row("reopen")

      assert read_event_ids() == [a.event_id]

      b = insert_observation("reopen", 2, "write second")

      repo().update_all(from(d in Distillation, where: d.subject_id == "reopen"),
        set: [status: "running"]
      )

      assert :ok = Distill.run("reopen")
      assert read_event_ids() == [b.event_id]

      assert %{status: "completed", records_written: 2, distilled_through_sequence: 2} =
               row("reopen")
    end

    test "a failure keeps completed chunks' progress and the retry resumes after them" do
      Application.put_env(:backplane_memory, :distill_provider, ChunkProvider)
      insert_row("partial")
      big = String.duplicate("x", 4_000)
      for seq <- 1..4, do: insert_observation("partial", seq, big)
      insert_observation("partial", 5, "write " <> big)
      insert_observation("partial", 6, "boom " <> big)

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = Distill.run("partial") end)

      failed = row("partial")
      assert %{status: "failed", records_written: 1, distilled_through_sequence: 5} = failed
      assert failed.last_error =~ "chunk 2/2"
      _ = reads()

      {:ok, _} = Distillations.retry("partial")
      ExUnit.CaptureLog.capture_log(fn -> assert :ok = Distill.run("partial") end)

      assert [%{"observations" => [%{"content" => "boom " <> _}]}] = reads()
      assert %{records_written: 1} = row("partial")
    end
  end

  describe "tool calling (finding 4)" do
    test "a model that never calls a tool fails the run naming the model" do
      Application.put_env(:backplane_memory, :distill_provider, TextOnlyProvider)
      insert_row("notools")
      insert_observation("notools", 1)

      ExUnit.CaptureLog.capture_log(fn -> assert :ok = Distill.run("notools") end)

      assert %{status: "failed", last_error: error} = row("notools")
      assert error =~ "made no tool calls"
      assert error =~ "memory.llm_model must support tool calling"
    end
  end
end
