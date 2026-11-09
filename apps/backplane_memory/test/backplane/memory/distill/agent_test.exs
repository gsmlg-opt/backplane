defmodule Backplane.Memory.Distill.AgentTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Distill.Agent, as: DistillAgent
  alias Backplane.Memory.Record

  # Pops one scripted response per provider call from an Agent held in the context.
  defmodule ScriptedProvider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, %{script: script, test_pid: test_pid}) do
      send(test_pid, {:provider_request, request})

      case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
        {:tool, id, name, arguments} ->
          call = %{id: id, name: name, arguments: arguments}

          [
            %{type: :response_started},
            %{type: :tool_call_completed, tool_call: call},
            %{
              type: :response_completed,
              message: %{role: :assistant, content: [Map.put(call, :type, :tool_call)]}
            }
          ]

        {:text, text} ->
          [
            %{type: :response_started},
            %{type: :response_completed, message: %{role: :assistant, content: text}}
          ]

        {:fail, error} ->
          [%{type: :response_started}, %{type: :response_failed, error: error}]
      end
    end
  end

  setup do
    event_id = Ecto.UUID.generate()

    chunk = [
      %{
        "event_id" => event_id,
        "at" => "2026-11-01T10:00:00.000000Z",
        "type" => "tool_use",
        "tool" => "Bash",
        "content" => "cd ~/Workspace/backplane && mix test"
      }
    ]

    session = %{
      subject_id: "subj-agent",
      host_id: "host-a",
      session_id: "sess-agent",
      agent_id: "claude",
      integration: "claude_code",
      mode: "distill"
    }

    %{chunk: chunk, session: session, event_id: event_id}
  end

  defp script(steps) do
    {:ok, pid} = Agent.start_link(fn -> steps end)
    pid
  end

  test "searches, writes and completes; returns one record written",
       %{chunk: chunk, session: session, event_id: event_id} do
    steps =
      script([
        {:tool, "c0", "read_chunk", %{}},
        {:tool, "c1", "search_memory", %{"query" => "backplane repo"}},
        {:tool, "c2", "write_memory",
         %{
           "kind" => "fact",
           "content" => "repo backplane lives at ~/Workspace/backplane on host-a",
           "subjects" => [%{"type" => "repo", "key" => "backplane"}],
           "property" => "path",
           "source_event_ids" => [event_id]
         }},
        {:text, "Done."}
      ])

    assert {:ok, %{records_written: 1}} =
             DistillAgent.run_chunk(session, chunk, "distill",
               provider: ScriptedProvider,
               provider_context: %{script: steps, test_pid: self()},
               chunk_index: 0
             )

    assert_received {:provider_request, first}
    assert [%{role: :system, content: system} | _] = first.messages
    assert system =~ "search_memory"

    assert Enum.sort(Enum.map(first.tools, & &1.name)) ==
             ~w(forget_memory read_chunk replace_memory search_memory write_memory)

    assert [record] = repo().all(Record)
    assert record.writer == "memory_agent"
    assert record.source_event_ids == [event_id]
  end

  test "a model mistake is returned to the model and the run continues",
       %{chunk: chunk, session: session} do
    steps =
      script([
        {:tool, "c0", "read_chunk", %{}},
        {:tool, "c1", "write_memory",
         %{"kind" => "fact", "content" => "x", "source_event_ids" => ["nope"]}},
        {:text, "Nothing worth remembering."}
      ])

    assert {:ok, %{records_written: 0}} =
             DistillAgent.run_chunk(session, chunk, "distill",
               provider: ScriptedProvider,
               provider_context: %{script: steps, test_pid: self()}
             )

    assert_received {:provider_request, _}
    assert_received {:provider_request, _}
    assert_received {:provider_request, third}

    assert %{result: %{content: "error: " <> _, is_error: false}} =
             third.messages |> Enum.filter(&(&1[:role] == :tool)) |> List.last()

    assert repo().aggregate(Record, :count) == 0
  end

  test "a failing provider returns the failure reason", %{chunk: chunk, session: session} do
    steps = script([{:fail, "LLM proxy returned HTTP 400 for model m: tools unsupported"}])

    assert {:error, reason} =
             DistillAgent.run_chunk(session, chunk, "distill",
               provider: ScriptedProvider,
               provider_context: %{script: steps, test_pid: self()}
             )

    assert is_binary(reason)
    assert reason =~ "HTTP 400"
  end

  test "a model that completes without calling read_chunk is an error naming the model",
       %{chunk: chunk, session: session} do
    steps = script([{:text, "Nothing to do."}])

    assert {:error, reason} =
             DistillAgent.run_chunk(session, chunk, "distill",
               provider: ScriptedProvider,
               provider_context: %{script: steps, test_pid: self()},
               model: "text-only-model"
             )

    assert reason ==
             "model text-only-model made no tool calls; memory.llm_model must support tool calling"
  end
end
