defmodule Backplane.AgentRuntime.ConversationWorkBudgetTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Backend do
    def execute(_operation), do: {:ok, %{text: "completed"}}
  end

  defp start(work) do
    {:ok, store} = EphemeralStore.new(1)

    {:ok, registry} =
      ToolRegistry.register(%ToolRegistry{}, %{
        tool_name: "read",
        tool_revision: 1,
        schema: %{"type" => "object", "properties" => %{}},
        safety: %{read_only: true, retry_safe: true, parallel_safe: false},
        backend: Backend
      })

    options = [
      run_id: "long-run",
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: self()},
      subscriber: self(),
      registry: registry,
      authority: %{caller: "host", run_id: "long-run", grants: ["read"], tool_revision: 1},
      work: work,
      run_timeout: :infinity
    ]

    pid = start_supervised!({Conversation, options}, id: make_ref())
    {pid, store, options}
  end

  defp done(text), do: %{type: :response_completed, message: %{role: :assistant, content: text}}

  defp perform_tools(count) do
    for index <- 1..count do
      assert_receive {:provider, _, provider}, 1_000

      send(
        provider,
        {:events,
         [
           %{
             type: :tool_call_completed,
             tool_call: %{id: "call-#{index}", name: "read", arguments: %{}}
           },
           done("read #{index}")
         ]}
      )
    end
  end

  test "unlimited work completes more than 100 provider and tool steps and restores without replay" do
    {pid, store, options} = start(:infinity)
    assert {:ok, _} = Conversation.prompt(pid, "complete 51 reads")
    perform_tools(51)
    assert_receive {:provider, _, provider}, 1_000
    send(provider, {:events, [done("finished")]})
    assert_receive {:agent_runtime, "long-run", %{type: :run_completed}}, 1_000

    assert {:ok, %{run: run}} = EphemeralStore.load(store, "long-run")
    assert run.execution_budget.quota == :infinity
    assert run.execution_budget.used == 103
    assert map_size(run.execution_budget.reservations) == 103
    assert map_size(run.tool_results) == 51
    GenServer.stop(pid)

    restored =
      start_supervised!({Conversation, Keyword.put(options, :run, run)}, id: make_ref())

    assert Conversation.status(restored).phase == :terminal
    assert Conversation.status(restored).run == run
    refute_receive {:provider, _, _}, 20
    assert {:ok, %{run: ^run}} = EphemeralStore.load(store, "long-run")
  end

  test "a finite 100-unit budget still settles before starting provider step 101" do
    {pid, store, _} = start(100)
    assert {:ok, _} = Conversation.prompt(pid, "complete 51 reads")
    perform_tools(50)
    assert_receive {:agent_runtime, "long-run", %{type: :run_failed}}, 1_000
    refute_receive {:provider, _, _}, 20
    assert Conversation.status(pid).run.state == :failed
    assert {:ok, %{run: run}} = EphemeralStore.load(store, "long-run")
    assert run.execution_budget.quota == 100
    assert run.execution_budget.used == 100
    assert map_size(run.tool_results) == 50
  end

  test "restoring unfinished unlimited work retains accounting and requires recovery" do
    {pid, store, options} = start(:infinity)
    assert {:ok, _} = Conversation.prompt(pid, "read and continue")
    perform_tools(1)
    assert_receive {:provider, _, _}, 1_000
    assert {:ok, %{run: run}} = EphemeralStore.load(store, "long-run")
    assert run.execution_budget.quota == :infinity
    assert run.execution_budget.used == 3
    GenServer.stop(pid)

    restored =
      start_supervised!({Conversation, Keyword.put(options, :run, run)}, id: make_ref())

    assert Conversation.status(restored).phase == :recovery_required
    assert Conversation.status(restored).run == run
    assert {:error, _} = Conversation.prompt(restored, "do not replay")
    refute_receive {:provider, _, _}, 20
    assert {:ok, %{run: ^run}} = EphemeralStore.load(store, "long-run")
  end
end
