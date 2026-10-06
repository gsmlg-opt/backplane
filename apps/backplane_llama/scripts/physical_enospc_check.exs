# Run through physical_enospc_check.py, which owns a disposable 16 MiB RAM disk.
import ExUnit.Assertions

alias Backplane.Audio.Config
alias Backplane.Audio.Media.TempFiles

root = System.fetch_env!("BACKPLANE_AUDIO_ENOSPC_ROOT")
probe = Path.join(root, "marker-probe")
assert File.dir?(probe)
assert {:error, :enospc} = File.write(Path.join(probe, ".owner"), "owner")

gateway = Process.whereis(Backplane.LLM.RateLimiter.Server)
assert is_pid(gateway)
assert {:ok, manager} = TempFiles.start_link(name: :audio_physical_enospc, root: root)

try do
  assert Process.alive?(manager)
  refute TempFiles.ready?(manager)
  assert TempFiles.usage(manager) == %{requests: 0, reserved: 0}
  assert {:error, %{status: 503}} = TempFiles.create(self(), Config.policy(), manager)
  assert File.ls!(root) == ["marker-probe"]
  assert File.dir?(probe)
  assert Process.whereis(Backplane.LLM.RateLimiter.Server) == gateway
  assert is_map(:sys.get_state(gateway))

  IO.puts(
    "ENOSPC proved: precreated directory preserved; marker write fails; manager startup fails closed (mkdir or marker); storage stays alive and unready; gateway stays responsive"
  )
after
  GenServer.stop(manager)
end
