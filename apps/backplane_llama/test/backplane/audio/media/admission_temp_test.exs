defmodule Backplane.Audio.Media.AdmissionTempTest do
  use ExUnit.Case, async: false

  alias Backplane.Audio.Media.{Admission, TempFiles}

  @policy %{
    "media_processes" => 1,
    "concurrent_uploads" => 1,
    "concurrent_operations" => 2,
    "temporary_storage_bytes" => 100,
    "upload_bytes" => 50,
    "request_timeout_ms" => 1_000
  }

  test "admission rejects excess work without a queue and releases on owner death" do
    name = :audio_admission_test
    start_supervised!({Admission, name: name})

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, ref} = Admission.acquire(:media, owner, @policy, name)
    assert {:error, %{status: 429}} = Admission.acquire(:media, self(), @policy, name)
    send(owner, :stop)
    assert eventually(fn -> Admission.counts(name).media == 0 end)
    assert :ok = Admission.release(ref, name)
  end

  test "private files are reserved, copied under generated names, and removed on owner death" do
    root = Path.join(System.tmp_dir!(), "audio-temp-test-#{System.unique_integer([:positive])}")
    name = :audio_temp_test
    start_supervised!({TempFiles, name: name, root: root, policy: @policy})

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, handle} = TempFiles.create(owner, @policy, name)
    assert {:ok, path} = TempFiles.path(handle, :input, name)
    assert String.starts_with?(path, root)
    assert :ok = TempFiles.reserve(handle, 80, name)
    assert {:error, %{code: "audio_storage_exhausted"}} = TempFiles.reserve(handle, 30, name)
    assert :ok = TempFiles.release_reservation(handle, 80, name)
    send(owner, :stop)
    assert eventually(fn -> TempFiles.usage(name).requests == 0 end)
    refute File.exists?(handle.dir)
    File.rm_rf(root)
  end

  test "reconciliation never releases another live pinned owner" do
    name = :audio_admission_reconcile_test
    start_supervised!({Admission, name: name})

    root =
      Path.join(System.tmp_dir!(), "audio-admission-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    live_dir = Path.join(root, "live")
    dead_dir = Path.join(root, "dead")
    File.mkdir_p!(live_dir)
    File.mkdir_p!(dead_dir)

    dead_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, live_ref} = Admission.acquire(:operation, self(), @policy, name)
    assert {:ok, dead_ref} = Admission.acquire(:operation, dead_owner, @policy, name)
    assert :ok = Admission.pin(live_ref, live_dir, name)
    assert :ok = Admission.pin(dead_ref, dead_dir, name)
    File.write!(live_dir <> ".cleanup-confirmed", "clean\n")
    send(dead_owner, :stop)
    Process.sleep(1_100)
    assert Admission.counts(name).operation == 2

    File.write!(dead_dir <> ".cleanup-confirmed", "clean\n")
    assert eventually(fn -> Admission.counts(name).operation == 1 end, 150)
    assert :ok = Admission.release(live_ref, name)
    assert Admission.counts(name).operation == 0
    File.rm_rf(root)
  end

  test "restart keeps uncertain files and disables new storage until guardian confirmation" do
    root =
      Path.join(System.tmp_dir!(), "audio-restart-test-#{System.unique_integer([:positive])}")

    name = :audio_temp_restart_test
    {:ok, first} = TempFiles.start_link(name: name, root: root, policy: @policy)
    {:ok, handle} = TempFiles.create(self(), @policy, name)
    assert :ok = TempFiles.reserve(handle, 40, name)
    assert :ok = TempFiles.pin(handle, name)
    GenServer.stop(first)
    assert File.dir?(handle.dir)

    {:ok, second} = TempFiles.start_link(name: name, root: root, policy: @policy)
    refute TempFiles.ready?(name)
    assert {:error, %{code: "audio_unavailable"}} = TempFiles.create(self(), @policy, name)
    File.write!(handle.dir <> ".cleanup-confirmed", "clean\n")
    assert eventually(fn -> TempFiles.ready?(name) end, 150)
    refute File.exists?(handle.dir)
    GenServer.stop(second)
    File.rm_rf(root)
  end

  test "periodic janitor never deletes current live requests, even with an old confirmation" do
    root = Path.join(System.tmp_dir!(), "audio-live-#{System.unique_integer([:positive])}")
    name = :audio_live_temp
    start_supervised!({TempFiles, name: name, root: root, policy: @policy})
    {:ok, handle} = TempFiles.create(self(), @policy, name)
    :ok = TempFiles.reserve(handle, 40, name)
    File.write!(Path.join(handle.dir, "input.media"), "live")
    send(name, :janitor_tick)
    assert TempFiles.usage(name) == %{requests: 1, reserved: 40}
    assert File.dir?(handle.dir)
    :ok = TempFiles.pin(handle, name)
    File.write!(handle.dir <> ".cleanup-confirmed", "clean\n")
    send(name, :janitor_tick)
    assert TempFiles.usage(name) == %{requests: 1, reserved: 40}
    assert File.dir?(handle.dir)
    :ok = TempFiles.unpin(handle, name)
    :ok = TempFiles.release(handle, name)
    File.rm_rf(root)
  end

  test "dead pinned entries keep quota until a regular trusted confirmation arrives" do
    root = Path.join(System.tmp_dir!(), "audio-dead-#{System.unique_integer([:positive])}")
    name = :audio_dead_temp
    start_supervised!({TempFiles, name: name, root: root, policy: @policy})

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, handle} = TempFiles.create(owner, @policy, name)
    :ok = TempFiles.reserve(handle, 80, name)
    :ok = TempFiles.pin(handle, name)
    send(owner, :stop)
    assert eventually(fn -> not Process.alive?(owner) end)
    send(name, :janitor_tick)
    assert TempFiles.usage(name).reserved == 80
    forged = Path.join(handle.dir, "fake-proof")
    File.write!(forged, "clean\n")
    File.ln_s!(forged, handle.dir <> ".cleanup-confirmed")
    send(name, :janitor_tick)
    assert TempFiles.usage(name).requests == 1
    File.rm!(handle.dir <> ".cleanup-confirmed")
    File.write!(handle.dir <> ".cleanup-confirmed", "clean\n")

    assert eventually(fn ->
             send(name, :janitor_tick)
             TempFiles.usage(name).requests == 0
           end)

    refute File.exists?(handle.dir)
    assert TempFiles.usage(name).reserved == 0
    File.rm_rf(root)
  end

  test "another live manager sharing this VM and root is never collected" do
    root =
      Path.join(System.tmp_dir!(), "audio-two-managers-#{System.unique_integer([:positive])}")

    {:ok, first} = TempFiles.start_link(name: :audio_first_manager, root: root, policy: @policy)
    {:ok, handle} = TempFiles.create(self(), @policy, :audio_first_manager)
    {:ok, second} = TempFiles.start_link(name: :audio_second_manager, root: root, policy: @policy)
    send(second, :janitor_tick)
    refute TempFiles.ready?(:audio_second_manager)
    assert File.dir?(handle.dir)
    assert TempFiles.usage(:audio_first_manager).requests == 1
    GenServer.stop(first)
    send(second, :janitor_tick)
    assert TempFiles.ready?(:audio_second_manager)
    GenServer.stop(second)
    File.rm_rf(root)
  end

  @tag :tmp_dir
  test "unusable filesystem roots fail closed without crashing storage or the gateway", %{
    tmp_dir: dir
  } do
    root = Path.join(dir, "not-a-directory")
    File.write!(root, "existing-file")
    gateway = Process.whereis(Backplane.LLM.RateLimiter.Server)
    manager = start_supervised!({TempFiles, name: :audio_failed_root, root: root})
    assert Process.alive?(manager)
    refute TempFiles.ready?(manager)
    assert TempFiles.usage(manager) == %{requests: 0, reserved: 0}
    assert {:error, %{status: 503}} = TempFiles.create(self(), @policy, manager)
    assert File.read!(root) == "existing-file"
    assert Process.whereis(Backplane.LLM.RateLimiter.Server) == gateway
    assert is_map(:sys.get_state(gateway))
  end

  @tag :tmp_dir
  test "successful boot directory and owner marker have private permissions", %{tmp_dir: dir} do
    manager = start_supervised!({TempFiles, name: :audio_private_boot, root: dir})
    assert TempFiles.ready?(manager)
    [boot] = File.ls!(dir)
    assert Bitwise.band(File.stat!(Path.join(dir, boot)).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(Path.join([dir, boot, ".owner"])).mode, 0o777) == 0o600
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
