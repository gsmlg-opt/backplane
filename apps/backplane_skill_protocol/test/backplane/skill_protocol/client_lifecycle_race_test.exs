Backplane.SkillProtocol.InstrumentedClientCompiler.compile!()

defmodule Backplane.SkillProtocol.ClientLifecycleRaceTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Client, Error, SkillRef, StartupInstrumentedClient}

  setup_all do
    on_exit(fn ->
      :code.delete(StartupInstrumentedClient)
      :code.purge(StartupInstrumentedClient)
    end)

    :ok
  end

  for exit_kind <- [:normal, :abnormal] do
    test "#{exit_kind} owner death during guardian startup leaves no worker" do
      controller = self()

      transport = fn
        {:startup_test_barrier, :before_owner_monitor, guardian, owner} ->
          send(controller, {:before_owner_monitor, guardian, owner})
          await_release({:release_before_owner_monitor, guardian})

        {:startup_test_barrier, :after_worker_spawn, guardian, owner, worker} ->
          send(controller, {:after_worker_spawn, guardian, owner, worker})
          await_release({:release_after_worker_spawn, guardian})

        request when is_map(request) ->
          receive do
            :never -> {:ok, %{status: 200, headers: %{}, body: catalog_body()}}
          end
      end

      owner =
        spawn(fn ->
          cancelled? = fn ->
            receive do
              :exit_normally -> exit(:normal)
            after
              0 -> false
            end
          end

          StartupInstrumentedClient.catalog(
            instrumented_client(transport, cancelled?: cancelled?)
          )
        end)

      owner_monitor = Process.monitor(owner)
      assert_receive {:before_owner_monitor, guardian, ^owner}, 500
      guardian_monitor = Process.monitor(guardian)
      on_exit(fn -> stop_processes([owner, guardian]) end)

      case unquote(exit_kind) do
        :normal -> send(owner, :exit_normally)
        :abnormal -> Process.exit(owner, :kill)
      end

      expected_reason = if unquote(exit_kind) == :normal, do: :normal, else: :killed
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, ^expected_reason}, 500
      send(guardian, {:release_before_owner_monitor, guardian})

      assert_receive {:after_worker_spawn, ^guardian, ^owner, worker}, 500
      worker_monitor = Process.monitor(worker)
      send(guardian, {:release_after_worker_spawn, guardian})

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 500
    end
  end

  test "overlapping requests keep replies and lifecycle actions isolated" do
    controller = self()
    cancelled = :atomics.new(1, [])

    payloads = %{
      "cancel" => "cancelled payload",
      "terminate" => "terminated payload",
      "alpha" => "alpha payload",
      "beta" => "beta payload"
    }

    transport = fn request ->
      skill_id =
        request.url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("skill_id")

      send(controller, {:overlap_started, skill_id, self()})

      receive do
        {:release, ^skill_id} ->
          {:ok, %{status: 200, headers: %{}, body: Map.fetch!(payloads, skill_id)}}
      end
    end

    shared_client = client(transport)

    operations =
      for skill_id <- Map.keys(payloads), into: %{} do
        call_opts =
          if skill_id == "cancel",
            do: [cancelled?: fn -> :atomics.get(cancelled, 1) == 1 end],
            else: []

        owner =
          spawn(fn ->
            initial = process_state()

            result =
              Client.artifact(
                shared_client,
                ref(skill_id, Map.fetch!(payloads, skill_id)),
                call_opts
              )

            send(controller, {:overlap_result, skill_id, result, initial, process_state()})
          end)

        {skill_id, %{owner: owner, owner_monitor: Process.monitor(owner)}}
      end

    on_exit(fn ->
      stop_processes(Enum.map(operations, fn {_id, operation} -> operation.owner end))
    end)

    operations =
      Enum.reduce(1..map_size(payloads), operations, fn _, operations ->
        assert_receive {:overlap_started, skill_id, worker}, 500
        guardian = guardian_for!(worker)
        owner = operations |> Map.fetch!(skill_id) |> Map.fetch!(:owner)
        assert guardian_monitors?(guardian, owner, worker)

        put_in(operations, [skill_id], %{
          owner: owner,
          owner_monitor: operations[skill_id].owner_monitor,
          worker: worker,
          worker_monitor: Process.monitor(worker),
          guardian: guardian,
          guardian_monitor: Process.monitor(guardian)
        })
      end)

    on_exit(fn ->
      operations
      |> Enum.flat_map(fn {_id, operation} -> [operation.worker, operation.guardian] end)
      |> stop_processes()
    end)

    :atomics.put(cancelled, 1, 1)
    Process.exit(operations["terminate"].owner, :kill)
    send(operations["alpha"].worker, {:release, "alpha"})
    send(operations["beta"].worker, {:release, "beta"})

    assert_clean_result(operations, "cancel", {:error, :cancelled})
    assert_clean_result(operations, "alpha", {:ok, "alpha payload"})
    assert_clean_result(operations, "beta", {:ok, "beta payload"})

    terminated = operations["terminate"]

    assert_receive {:DOWN, terminated_owner_monitor, :process, terminated_owner, :killed}, 500
    assert terminated_owner_monitor == terminated.owner_monitor
    assert terminated_owner == terminated.owner
    assert_receive {:DOWN, terminated_worker_monitor, :process, terminated_worker, :killed}, 500
    assert terminated_worker_monitor == terminated.worker_monitor
    assert terminated_worker == terminated.worker

    assert_receive {:DOWN, terminated_guardian_monitor, :process, terminated_guardian, :normal},
                   500

    assert terminated_guardian_monitor == terminated.guardian_monitor
    assert terminated_guardian == terminated.guardian
    refute_receive {:overlap_result, "terminate", _, _, _}
  end

  defp assert_clean_result(operations, skill_id, expected) do
    %{
      worker: worker,
      worker_monitor: worker_monitor,
      guardian: guardian,
      guardian_monitor: guardian_monitor,
      owner: owner,
      owner_monitor: owner_monitor
    } = Map.fetch!(operations, skill_id)

    case expected do
      {:error, code} ->
        assert_receive {:overlap_result, ^skill_id, {:error, %Error{code: ^code}}, initial,
                        final},
                       500

        assert final == initial

      {:ok, payload} ->
        assert_receive {:overlap_result, ^skill_id, {:ok, ^payload}, initial, final}, 500
        assert final == initial
    end

    worker_reason = if skill_id == "cancel", do: :killed, else: :normal

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, ^worker_reason}, 500
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :normal}, 500
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 500
  end

  defp guardian_for!(worker) do
    {:links, [guardian]} = Process.info(worker, :links)
    guardian
  end

  defp guardian_monitors?(guardian, owner, worker) do
    {:monitors, monitors} = Process.info(guardian, :monitors)
    Enum.sort(monitors) == Enum.sort(process: owner, process: worker)
  end

  defp process_state do
    {Process.info(self(), :monitors), Process.info(self(), :messages)}
  end

  defp ref(skill_id, payload) do
    %SkillRef{
      source_id: "source-a",
      skill_id: skill_id,
      revision: "r1",
      artifact_digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
    }
  end

  defp client(transport) do
    Client.new!(
      endpoint: "https://backplane.example",
      source_id: "source-a",
      access_context_id: "tenant-a",
      credential_supplier: fn -> nil end,
      transport: transport,
      max_attempts: 1,
      overall_timeout_ms: 10_000
    )
  end

  defp instrumented_client(transport, opts) do
    StartupInstrumentedClient.new!(
      Keyword.merge(
        [
          endpoint: "https://backplane.example",
          source_id: "source-a",
          access_context_id: "tenant-a",
          credential_supplier: fn -> nil end,
          transport: transport,
          max_attempts: 1,
          overall_timeout_ms: 10_000
        ],
        opts
      )
    )
  end

  defp await_release(message) do
    receive do
      ^message -> :ok
    end
  end

  defp catalog_body do
    JSON.encode!(%{"protocol_version" => "1", "data" => [], "next_cursor" => nil})
  end

  defp stop_processes(processes) do
    Enum.each(processes, fn process ->
      if Process.alive?(process) do
        monitor = Process.monitor(process)
        Process.exit(process, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^process, _reason} -> :ok
        after
          500 -> :ok
        end
      end
    end)
  end
end
