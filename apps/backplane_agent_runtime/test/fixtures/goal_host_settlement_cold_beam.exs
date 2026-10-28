Code.require_file("goal_file_store.exs", __DIR__)

defmodule Backplane.AgentRuntime.GoalHostSettlementColdBeamFixture do
  import ExUnit.Assertions
  alias Backplane.AgentRuntime.{Error, Goal, GoalFileStore}

  defmodule Store do
    def load(ctx, thread), do: GoalFileStore.load(ctx.store, thread)

    def compare_and_swap(ctx, thread, revision, goal_id, next) do
      with {:ok, committed} <-
             GoalFileStore.compare_and_swap(ctx.store, thread, revision, goal_id, next) do
        if Agent.get_and_update(ctx.gate, &{&1, false}),
          do: {:error, Error.new(:transient_transport, "lost host settlement acknowledgement")},
          else: {:ok, committed}
      end
    end
  end

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
        if state.reserved === admission and state.phase == :reserved and
             not Enum.any?(state.seals, &(&1 === admission)),
           do: {:released, %{state | phase: :released}},
           else: {:fenced, state}
      end)
    end

    def restore_seal(host, admission) do
      Agent.update(host, &%{&1 | seals: [admission | &1.seals]})
    end

    def seal_after_down(host, admission) do
      Agent.get_and_update(host, fn state ->
        assert state.reserved == admission
        assert state.phase == :released

        {:sealed,
         %{
           state
           | phase: :sealed,
             reserved: nil,
             generation: state.generation + 1,
             seals: [admission | state.seals]
         }}
      end)
    end
  end

  def run(mode, dir) do
    File.mkdir_p!(dir)
    {:ok, store} = GoalFileStore.start_link(Path.join(dir, "store"))
    {:ok, gate} = Agent.start_link(fn -> false end)
    generation = if mode == "producer", do: 1, else: 3

    {:ok, host} =
      Agent.start_link(fn -> %{generation: generation, reserved: nil, phase: nil, seals: []} end)

    {:ok, goal} =
      Goal.start_link(
        thread_id: "cold-thread",
        owner_pid: self(),
        store: Store,
        store_context: %{store: store, gate: gate},
        host: Host,
        host_context: host
      )

    case mode do
      "producer" -> produce(goal, host, gate, dir)
      "consumer" -> consume(goal, host, store, dir)
    end
  end

  defp produce(goal, host, gate, dir) do
    assert {:ok, _} = Goal.set(goal, %{objective: "original"}, %{text: "original"})
    assert {:ok, {:started, admission}} = Goal.idle(goal, 1)
    assert :released = Host.release(host, admission)
    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {output, 0} =
          System.cmd(System.find_executable("sh"), [
            "-c",
            "printf x >> \"$1\"; printf '%s' '{\"continue\":false,\"stopReason\":\"host hook veto\"}'",
            "host-hook",
            Path.join(dir, "effect-marker")
          ])

        JSON.decode!(output)
      end)

    ref = task.ref
    pid = task.pid
    assert_receive {^ref, result}, 2_000
    assert result == %{"continue" => false, "stopReason" => "host hook veto"}
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
      effects: %{
        kind: :host_pre_runtime,
        records: [%{effect_id: "host-hook", kind: "UserPromptSubmit", result: result}],
        result: %{"status" => "stopped", "stopReason" => result["stopReason"]},
        cleanup: :confirmed
      }
    }

    Agent.update(gate, fn _ -> true end)

    assert {:error, %Error{class: :transient_transport}} =
             Goal.settle_host_admission(goal, admission, :host_stopped, attestation)

    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(goal, 2)
    assert File.read!(Path.join(dir, "effect-marker")) == "x"
    File.write!(Path.join(dir, "host-seal.term"), :erlang.term_to_binary(admission))
    File.write!(Path.join(dir, "retry.term"), :erlang.term_to_binary({admission, attestation}))

    IO.puts(
      JSON.encode!(%{
        producer_os_pid: System.pid(),
        executor_down: true,
        sealed: true,
        persisted_ack_lost: true,
        settlement: "host_stopped",
        goal_active: true
      })
    )
  end

  defp consume(goal, host, store, dir) do
    {admission, attestation} =
      dir |> Path.join("retry.term") |> File.read!() |> :erlang.binary_to_term([:safe])

    # Re-establish host custody from its own durable seal, never from Goal's ledger.
    assert ^admission =
             dir |> Path.join("host-seal.term") |> File.read!() |> :erlang.binary_to_term([:safe])

    :ok = Host.restore_seal(host, admission)
    assert :fenced = Host.release(host, admission)
    assert {:ok, {:started, current}} = Goal.idle(goal, 3)
    assert current.reservation_token != admission.reservation_token
    assert {:ok, before_retry} = GoalFileStore.load(store, "cold-thread")

    assert {:ok, {:settled, :host_stopped}} =
             Goal.settle_host_admission(goal, admission, :host_stopped, attestation)

    assert {:ok, ^before_retry} = GoalFileStore.load(store, "cold-thread")
    assert {:ok, %{goal: %{objective: "original", status: :active}}} = Goal.get(goal)
    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(goal, 3)

    assert {:error, %Error{class: :resource_conflict}} =
             Goal.settle_host_admission(goal, admission, :superseded, attestation)

    assert {:ok, ^before_retry} = GoalFileStore.load(store, "cold-thread")
    assert File.read!(Path.join(dir, "effect-marker")) == "x"
    assert :fenced = Host.release(host, admission)

    IO.puts(
      JSON.encode!(%{
        consumer_os_pid: System.pid(),
        historical_ack: true,
        original_effect_occurrences: 1,
        goal_preserved: true,
        newer_reservation_preserved: true,
        store_unchanged: true
      })
    )
  end
end

[mode, dir] = System.argv()
Backplane.AgentRuntime.GoalHostSettlementColdBeamFixture.run(mode, dir)
