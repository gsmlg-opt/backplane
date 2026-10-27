Code.require_file("goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalSettlementColdBeamFixture do
  import ExUnit.Assertions
  alias Backplane.AgentRuntime.{Error, Execution, Goal, GoalFileStore}

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(_, _, _), do: :ok

    def start_turn_if_idle(host, _thread, request) do
      Agent.get_and_update(host, fn state ->
        if state.reserved != nil or state.generation != request.host_generation do
          {{:ok, {:not_submitted, :busy}}, state}
        else
          admission =
            Map.merge(Map.take(request, [:host_generation, :reservation_token]), %{
              run_id: "cold-#{state.generation}",
              incarnation: 1,
              turn_id: "logical-#{state.generation}"
            })

          {{:ok, {:started, admission}}, %{state | reserved: admission, phase: :reserved}}
        end
      end)
    end

    def release(host, admission) do
      Agent.get_and_update(host, fn state ->
        if state.reserved == admission and state.phase == :reserved,
          do: {:released, %{state | phase: :released}},
          else: {:fenced, state}
      end)
    end

    def seal_after_down(host, admission) do
      Agent.get_and_update(host, fn state ->
        assert state.reserved == admission
        assert state.phase == :released
        {:sealed, %{state | phase: :sealed, reserved: nil, generation: state.generation + 1}}
      end)
    end
  end

  def run(mode, dir) do
    File.mkdir_p!(dir)
    {:ok, store} = GoalFileStore.start_link(Path.join(dir, "store"))
    generation = if mode == "producer", do: 1, else: 3

    {:ok, host} =
      Agent.start_link(fn -> %{generation: generation, reserved: nil, phase: nil} end)

    {:ok, goal} =
      Goal.start_link(
        thread_id: "cold-thread",
        owner_pid: self(),
        store: GoalFileStore,
        store_context: store,
        host: Host,
        host_context: host
      )

    case mode do
      "producer" -> produce(goal, host, dir)
      "consumer" -> consume(goal, host, store, dir)
    end
  end

  defp produce(goal, host, dir) do
    assert {:ok, _} = Goal.set(goal, %{objective: "original"}, %{text: "original"})
    assert {:ok, {:started, admission}} = Goal.idle(goal, 1)
    assert :released = Host.release(host, admission)
    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Execution.validate_limits(cleanup_timeout: 0)
      end)

    ref = task.ref
    pid = task.pid
    assert_receive {^ref, {:error, %Error{class: :validation}}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert :sealed = Host.seal_after_down(host, admission)
    assert :fenced = Host.release(host, admission)

    attestation = %{
      admission:
        Map.take(admission, [
          :run_id,
          :incarnation,
          :turn_id,
          :host_generation,
          :reservation_token
        ]),
      executor: :confirmed_down,
      runtime_admission: :never_started,
      future_start: :fenced,
      effects: :none_dispatched
    }

    assert {:ok, {:settled, :cancelled}} =
             Goal.settle_unstarted_admission(goal, admission, :cancelled, attestation)

    assert {:ok, _} = Goal.clear(goal, %{text: "replace original"})
    assert {:ok, _} = Goal.set(goal, %{objective: "replacement"}, %{text: "replacement"})
    assert {:ok, {:started, newer}} = Goal.idle(goal, 2)
    assert newer.reservation_token != admission.reservation_token
    File.write!(Path.join(dir, "retry.term"), :erlang.term_to_binary({admission, attestation}))

    IO.puts(
      Jason.encode!(%{
        producer_os_pid: System.pid(),
        executor_down: true,
        sealed: true,
        settlement: "cancelled",
        replacement: true
      })
    )
  end

  defp consume(goal, _host, store, dir) do
    {admission, attestation} =
      dir |> Path.join("retry.term") |> File.read!() |> :erlang.binary_to_term([:safe])

    assert {:ok, {:started, current}} = Goal.idle(goal, 3)
    assert current.reservation_token != admission.reservation_token
    assert {:ok, before_retry} = GoalFileStore.load(store, "cold-thread")

    assert {:ok, {:settled, :cancelled}} =
             Goal.settle_unstarted_admission(goal, admission, :cancelled, attestation)

    assert {:ok, ^before_retry} = GoalFileStore.load(store, "cold-thread")
    assert {:ok, %{goal: %{objective: "replacement", status: :active}}} = Goal.get(goal)
    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(goal, 3)

    assert {:error, %Error{class: :resource_conflict}} =
             Goal.settle_unstarted_admission(goal, admission, :preparation_failed, attestation)

    assert {:ok, ^before_retry} = GoalFileStore.load(store, "cold-thread")

    IO.puts(
      Jason.encode!(%{
        consumer_os_pid: System.pid(),
        historical_ack: true,
        replacement_preserved: true,
        newer_reservation_preserved: true,
        store_unchanged: true
      })
    )
  end
end

[mode, dir] = System.argv()
Backplane.AgentRuntime.GoalSettlementColdBeamFixture.run(mode, dir)
