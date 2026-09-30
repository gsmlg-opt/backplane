defmodule Backplane.AgentRuntime.CodexMultiAgentCloseTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{EphemeralStore, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.MultiAgent

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, self()})

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

  defp child_options(test_pid, _request, run_id, _parent) do
    {:ok, store} = EphemeralStore.new(1)

    {:ok,
     [
       run_id: run_id,
       store: EphemeralStore,
       context: store,
       provider: Provider,
       provider_context: %{test: test_pid},
       registry: %ToolRegistry{},
       tools: [],
       authority: %{caller: "host", run_id: run_id, grants: []},
       schema_admission: :strict,
       work: 10,
       run_timeout: 5_000
     ]}
  end

  defp start_runtime(test_pid) do
    MultiAgent.start_link(
      parent_run_id: "root",
      parent_name: "/root",
      parent_authority: %{caller: "host", run_id: "root", grants: []},
      child_options: &child_options(test_pid, &1, &2, &3),
      min_wait_timeout_ms: 0
    )
  end

  defp call(runtime, run_id, tool_name, arguments) do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: :v1},
      run_id: run_id,
      tool_name: tool_name,
      arguments: arguments
    })
  end

  defp spawn(runtime, task_message) do
    assert {:ok, %{agent_id: run_id}} =
             call(runtime, "root", "multi_agent_v1::spawn_agent", %{"message" => task_message})

    assert_receive {:provider, ^run_id, _provider}
    run_id
  end

  defp agent_name(run_id), do: run_id |> String.split(":") |> hd()

  test "repeated close is idempotent and preserves an unrelated peer" do
    {:ok, runtime} = start_runtime(self())
    child = spawn(runtime, "child")
    peer = spawn(runtime, "peer")
    peer_pid = :sys.get_state(runtime).agents[agent_name(peer)].pid

    assert {:ok, %{status: :shutdown}} =
             call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => child})

    assert {:ok, %{previous_status: :shutdown, status: :shutdown}} =
             call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => child})

    state = :sys.get_state(runtime)
    assert Process.alive?(runtime)
    assert Process.alive?(state.child_supervisor)
    assert Process.alive?(peer_pid)
    assert state.agents[agent_name(child)].status == :shutdown
    assert state.agents[agent_name(peer)].status == :running
  end

  test "closing a descendant before its parent skips the settled descendant" do
    {:ok, runtime} = start_runtime(self())
    parent = spawn(runtime, "parent")

    parent_name = agent_name(parent)
    nested_name = parent_name <> "/nested"

    assert {:ok, %{task_name: ^nested_name}} =
             call(runtime, parent, "multi_agent_v1::spawn_agent", %{
               "task_name" => "nested",
               "message" => "nested"
             })

    nested_run = :sys.get_state(runtime).agents[nested_name].run_id
    assert_receive {:provider, ^nested_run, _provider}

    assert {:ok, %{status: :shutdown}} =
             call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => nested_run})

    assert {:ok, %{status: :shutdown}} =
             call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => parent})

    state = :sys.get_state(runtime)
    assert state.agents[parent_name].status == :shutdown
    assert state.agents[nested_name].status == :shutdown
    assert state.agents[nested_name].pid == nil
    assert Process.alive?(runtime)
    assert Process.alive?(state.child_supervisor)
  end

  test "overlapping close and a late monitor notification do not kill the manager" do
    {:ok, runtime} = start_runtime(self())
    child = spawn(runtime, "child")
    ref = :sys.get_state(runtime).agents[agent_name(child)].monitor

    callers =
      for _ <- 1..2 do
        Task.async(fn ->
          call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => child})
        end)
      end

    assert Enum.all?(callers, &match?({:ok, %{status: :shutdown}}, Task.await(&1, 10_000)))
    send(runtime, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(20)

    state = :sys.get_state(runtime)
    assert Process.alive?(runtime)
    assert Process.alive?(state.child_supervisor)
    assert state.agents[agent_name(child)].status == :shutdown
  end

  test "failed settlement remains uncertain and a retry does not fabricate closure" do
    {:ok, runtime} = start_runtime(self())
    child = spawn(runtime, "uncertain")
    state = :sys.get_state(runtime)
    pid = state.agents[agent_name(child)].pid
    Process.exit(pid, :kill)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => child})

    state = :sys.get_state(runtime)
    agent = state.agents[agent_name(child)]
    assert agent.status == :interrupted
    assert match?({:uncertain, %Error{}}, agent.closure)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(runtime, "root", "multi_agent_v1::close_agent", %{"target" => child})

    assert Process.alive?(runtime)
    assert Process.alive?(state.child_supervisor)
  end
end
