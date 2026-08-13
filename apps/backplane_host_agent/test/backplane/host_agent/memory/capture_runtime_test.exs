defmodule Backplane.HostAgent.Memory.CaptureRuntimeTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{CaptureSupervisor, EventEnvelope, RecallCache}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool

  @moduletag :tmp_dir

  defmodule ChannelProvider do
    def channel do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, :channel_requested)

      case :persistent_term.get({__MODULE__, :result}, nil) do
        {:raise, reason} -> raise reason
        {:exit, reason} -> exit(reason)
        channel -> channel
      end
    end
  end

  defmodule FakeChannel do
    def push(channel, "memory_events", payload) do
      send(channel, {:memory_events, payload})

      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" =>
           Enum.map(payload["events"], &%{"event_id" => &1["event_id"], "status" => "accepted"})
       }}
    end
  end

  setup do
    previous_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)
    :persistent_term.put({ChannelProvider, :owner}, self())
    :persistent_term.put({ChannelProvider, :result}, nil)

    on_exit(fn ->
      :persistent_term.erase({ChannelProvider, :owner})
      :persistent_term.erase({ChannelProvider, :result})
      restore_env(:capture_runtime, previous_runtime)
    end)
  end

  test "capture supervisor owns a distinct durable spool and uploader", %{tmp_dir: dir} do
    names = names()
    db_path = Path.join(dir, "nested/capture.db")
    config = capture_config(db_path, names)

    assert {:ok, supervisor} = CaptureSupervisor.start_link(config)

    assert %{
             host_id: "host",
             config: %{host_id: "host"},
             spool: spool,
             spool_module: Spool,
             recall_cache: recall_cache
           } =
             Application.fetch_env!(:backplane_host_agent, :capture_runtime)

    assert spool == names.spool
    assert is_pid(Process.whereis(names.spool))
    assert is_pid(Process.whereis(names.uploader))
    assert recall_cache == names.recall_cache
    assert is_pid(Process.whereis(names.recall_cache))
    assert %{entries: 0, bytes: 0} = RecallCache.stats(names.recall_cache)

    assert %{
             max_spool_bytes: 67_108_864,
             max_event_age_ms: 2_592_000_000,
             retry_base_ms: 1_000,
             retry_max_ms: 300_000,
             compaction_batch_size: 100
           } = :sys.get_state(names.spool)

    assert {:ok, _} = Spool.append(names.spool, event("survives"))
    Supervisor.stop(supervisor)

    assert {:ok, restarted} = CaptureSupervisor.start_link(config)
    assert [%{"event_id" => "survives"}] = Spool.next_batch(names.spool, 100, 524_288)
    Supervisor.stop(restarted)
  end

  test "capture supervisor resolves the named spool encryption facility without reporting its key",
       %{
         tmp_dir: dir
       } do
    names = names()
    db_path = Path.join(dir, "encrypted-capture.db")
    env_name = "BACKPLANE_CAPTURE_RUNTIME_KEY_#{System.unique_integer([:positive])}"
    raw_key = Base.encode64(:crypto.strong_rand_bytes(32))
    System.put_env(env_name, raw_key)
    on_exit(fn -> System.delete_env(env_name) end)

    config =
      db_path
      |> capture_config(names)
      |> Map.put(:encryption_key_env, env_name)

    assert {:ok, supervisor} = CaptureSupervisor.start_link(config)
    assert {:ok, _} = Spool.append(names.spool, event("encrypted-runtime"))
    assert [%{"event_id" => "encrypted-runtime"}] = Spool.next_batch(names.spool, 100, 524_288)

    runtime = Application.fetch_env!(:backplane_host_agent, :capture_runtime)
    assert runtime.config.encryption_key_env == env_name
    refute inspect(runtime) =~ raw_key

    %{store: store} = :sys.get_state(names.spool)

    assert {:ok, %Turso.Result{rows: [%{"envelope_json" => stored}]}} =
             Backplane.HostAgent.Memory.Store.query(
               store,
               "SELECT envelope_json FROM capture_event_spool"
             )

    assert String.starts_with?(stored, "bpenc:v1:")
    refute stored =~ "encrypted-runtime"
    Supervisor.stop(supervisor)
  end

  test "disabled capture supervisor is ignored", %{tmp_dir: dir} do
    assert :ignore =
             CaptureSupervisor.start_link(%{
               enabled: false,
               db_path: Path.join(dir, "capture.db")
             })
  end

  test "capture supervisor restarts the spool and uploader after owned Store exits normally", %{
    tmp_dir: dir
  } do
    names = names()
    config = capture_config(Path.join(dir, "capture.db"), names)
    assert {:ok, supervisor} = CaptureSupervisor.start_link(config)

    old_spool = Process.whereis(names.spool)
    old_uploader = Process.whereis(names.uploader)
    %{store: store} = :sys.get_state(old_spool)
    spool_ref = Process.monitor(old_spool)

    GenServer.stop(store, :normal)
    assert_receive {:DOWN, ^spool_ref, :process, ^old_spool, _reason}, 1_000

    assert new_spool = await_replacement(names.spool, old_spool)
    assert Process.whereis(names.uploader) == old_uploader
    assert Process.alive?(old_uploader)
    assert %{store: new_store} = :sys.get_state(new_spool)
    assert new_store != store
    assert Process.alive?(new_store)
    assert {:ok, _} = Spool.append(new_spool, event("after-restart"))
    assert [%{"event_id" => "after-restart"}] = Spool.next_batch(new_spool, 100, 524_288)

    Supervisor.stop(supervisor)
  end

  test "periodic drain survives disconnect and uses a fresh channel after reconnect", %{
    tmp_dir: dir
  } do
    names = names()

    config =
      Path.join(dir, "capture.db")
      |> capture_config(names)
      |> Map.put(:upload_interval_ms, 10)

    assert {:ok, supervisor} = CaptureSupervisor.start_link(config)

    assert {:ok, _} = Spool.append(names.spool, event("reconnect"))
    uploader = Process.whereis(names.uploader)

    assert_receive :channel_requested, 200
    assert Process.alive?(uploader)
    assert [%{"event_id" => "reconnect"}] = Spool.next_batch(names.spool, 100, 524_288)

    channel = self()
    :persistent_term.put({ChannelProvider, :result}, channel)

    assert_receive :channel_requested, 200
    assert_receive {:memory_events, %{"events" => [%{"event_id" => "reconnect"}]}}, 200
    assert eventually(fn -> Spool.next_batch(names.spool, 100, 524_288) == [] end)

    Supervisor.stop(supervisor)
  end

  test "channel provider failures do not crash the uploader", %{tmp_dir: dir} do
    names = names()

    assert {:ok, supervisor} =
             CaptureSupervisor.start_link(capture_config(Path.join(dir, "capture.db"), names))

    uploader = Process.whereis(names.uploader)

    for failure <- [{:raise, "provider exploded"}, {:exit, :provider_closed}] do
      :persistent_term.put({ChannelProvider, :result}, failure)
      send(uploader, :drain)
      assert_receive :channel_requested
      assert Process.alive?(uploader)
    end

    Supervisor.stop(supervisor)
  end

  defp capture_config(db_path, names) do
    %{
      enabled: true,
      db_path: db_path,
      host_id: "host",
      name: names.supervisor,
      spool_name: names.spool,
      uploader_name: names.uploader,
      recall_cache_name: names.recall_cache,
      channel_provider: ChannelProvider,
      channel_module: FakeChannel,
      upload_interval_ms: 0,
      batch_size: 100,
      batch_bytes: 524_288
    }
  end

  defp names do
    suffix = System.unique_integer([:positive])

    %{
      supervisor: :"capture_supervisor_#{suffix}",
      spool: :"capture_spool_#{suffix}",
      uploader: :"capture_uploader_#{suffix}",
      recall_cache: :"capture_recall_cache_#{suffix}"
    }
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp event(event_id) do
    payload = %{"prompt" => event_id}

    %{
      schema_version: 1,
      event_id: event_id,
      idempotency_key: "idem-#{event_id}",
      integration: "claude_code",
      host_id: "host",
      agent_id: "agent",
      event_type: "claude_code.user_prompt",
      occurred_at: "2026-08-03T10:00:00Z",
      session_id: "session",
      payload: payload,
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: %{"filtered" => false, "redactions" => 0}
    }
  end

  defp await_replacement(name, old_pid, attempts \\ 100)
  defp await_replacement(_name, _old_pid, 0), do: nil

  defp await_replacement(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        await_replacement(name, old_pid, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_host_agent, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_host_agent, key, value)
end
