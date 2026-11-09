defmodule Backplane.Memory.Distill.ProviderTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}
  alias Backplane.Memory.Distill.Provider

  defmodule OneToolCall do
    def complete(messages, tools, opts) do
      send(opts[:test_pid], {:chat_request, messages, tools})

      {:ok,
       %{
         content: "Saving.",
         tool_calls: [%{id: "call_1", name: "noop", arguments: %{"note" => "x"}}],
         usage: %{"prompt_tokens" => 7, "completion_tokens" => 3}
       }}
    end
  end

  defmodule Failing do
    def complete(_messages, _tools, _opts),
      do: {:error, "LLM proxy returned HTTP 400 for model m: no tools"}
  end

  # Calls the tool once, then answers once the tool result is in the history.
  defmodule RoundTrip do
    def complete(messages, tools, opts) do
      send(opts[:test_pid], {:chat_request, messages, tools})

      if Enum.any?(messages, &(&1["role"] == "tool")) do
        {:ok, %{content: "All done.", tool_calls: [], usage: nil}}
      else
        {:ok,
         %{
           content: nil,
           tool_calls: [%{id: "call_1", name: "noop", arguments: %{"note" => "hello"}}],
           usage: nil
         }}
      end
    end
  end

  defmodule Noop do
    def execute(%{arguments: %{"note" => note}}), do: {:ok, %{content: "noted " <> note}}
  end

  @tool %{name: "noop", description: "Does nothing", parameters: %{"type" => "object"}}

  defp request(messages), do: %{messages: messages, tools: [@tool], run_id: "r", turn_id: "t"}

  test "emits started, one tool call, usage and a completed message carrying the call" do
    context = %{chat_client: OneToolCall, chat_opts: [test_pid: self()]}

    events =
      Provider.stream(
        request([%{role: :system, content: "sys"}, %{role: :user, content: "go"}]),
        context
      )
      |> Enum.to_list()

    assert [
             %{type: :response_started},
             %{type: :tool_call_completed, tool_call: call},
             %{type: :usage_updated, usage: usage},
             %{type: :response_completed, message: %{role: :assistant, content: content}}
           ] = events

    assert call == %{id: "call_1", name: "noop", arguments: %{"note" => "x"}}
    assert usage.input_tokens == 7
    assert usage.output_tokens == 3

    assert content == [
             %{type: :text, text: "Saving."},
             %{type: :tool_call, id: "call_1", name: "noop", arguments: %{"note" => "x"}}
           ]

    assert_received {:chat_request, messages, [@tool]}

    assert messages == [
             %{"role" => "system", "content" => "sys"},
             %{"role" => "user", "content" => "go"}
           ]
  end

  test "omits usage when the chat client returns none" do
    events =
      Provider.stream(request([]), %{chat_client: RoundTrip, chat_opts: [test_pid: self()]})
      |> Enum.to_list()

    assert [
             %{type: :response_started},
             %{type: :tool_call_completed},
             %{type: :response_completed}
           ] = events
  end

  test "ends in response_failed with the error string" do
    assert [
             %{type: :response_started},
             %{type: :response_failed, error: "LLM proxy returned HTTP 400 for model m: no tools"}
           ] = Provider.stream(request([]), %{chat_client: Failing}) |> Enum.to_list()
  end

  test "converts assistant tool calls and tool results to chat-completions messages" do
    messages = [
      %{role: :user, content: "go"},
      %{
        role: :assistant,
        content: [
          %{type: :text, text: "Calling."},
          %{type: :tool_call, id: "c1", name: "noop", arguments: %{"note" => "a"}}
        ]
      },
      %{role: :tool, tool_call_id: "c1", name: "noop", result: %{content: "ok", is_error: false}},
      %{
        role: :tool,
        tool_call_id: "c2",
        name: "noop",
        result: %{
          is_error: true,
          error: Backplane.AgentRuntime.Error.new(:validation, "bad input")
        }
      },
      %{role: :assistant, content: "plain"}
    ]

    Provider.stream(request(messages), %{chat_client: RoundTrip, chat_opts: [test_pid: self()]})
    |> Enum.to_list()

    assert_received {:chat_request, chat, _tools}

    assert [
             %{"role" => "user", "content" => "go"},
             %{
               "role" => "assistant",
               "content" => "Calling.",
               "tool_calls" => [
                 %{
                   "id" => "c1",
                   "type" => "function",
                   "function" => %{"name" => "noop", "arguments" => ~s({"note":"a"})}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "c1", "content" => "ok"},
             %{"role" => "tool", "tool_call_id" => "c2", "content" => error_text},
             %{"role" => "assistant", "content" => "plain"}
           ] = chat

    assert error_text =~ "bad input"
  end

  test "a Conversation round-trip through the adapter reaches run_completed" do
    {:ok, store} = EphemeralStore.new(1)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "noop",
        tool_revision: 1,
        backend: Noop,
        schema: %{
          "type" => "object",
          "properties" => %{"note" => %{"type" => "string"}},
          "required" => ["note"]
        },
        safety: %{read_only: true, retry_safe: true, parallel_safe: true}
      })

    run_id = "distill-provider-test-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Conversation.start_link(
        run_id: run_id,
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{chat_client: RoundTrip, chat_opts: [test_pid: self()]},
        registry: registry,
        subscriber: self(),
        authority: %{caller: "memory_test", run_id: run_id, grants: ["noop"], tool_revision: 1},
        messages: [%{role: :system, content: "You are the memory agent."}],
        work: 3,
        run_timeout: 5_000
      )

    {:ok, _} = Conversation.prompt(pid, "Distill this session")

    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000

    assert_received {:chat_request, first, tools}

    assert [%{"role" => "system"}, %{"role" => "user", "content" => "Distill this session"}] =
             first

    assert Enum.any?(tools, &(&1.name == "noop"))

    assert_received {:chat_request, second, _}

    assert [
             %{"role" => "system"},
             %{"role" => "user"},
             %{"role" => "assistant", "tool_calls" => [%{"id" => "call_1"}]},
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "noted hello"}
           ] = second

    GenServer.stop(pid)
  end
end
