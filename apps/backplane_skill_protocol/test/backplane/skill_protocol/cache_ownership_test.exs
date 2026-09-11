defmodule Backplane.SkillProtocol.CacheOwnershipTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Cache, Error}
  alias Backplane.SkillProtocol.Cache.{NativeLock, Ownership}

  @moduletag :tmp_dir
  @deadline 5_000

  defmodule UnavailableLock do
    def acquire(_path), do: {:error, :unavailable}
    def release(_handle), do: :ok
  end

  test "fresh and initialized roots have exactly one independent VM winner", %{tmp_dir: tmp_dir} do
    for initialized? <- [false, true] do
      root = Path.join(tmp_dir, "contended-#{initialized?}")

      if initialized? do
        initializer = start_owner(root, "shared-owner", :immediate)
        assert {:won, _output} = await_result(initializer)
        stop_owner(initializer)
        assert_exit(initializer)
      end

      first = start_owner(root, "shared-owner", :gated)
      second = start_owner(root, "shared-owner", :gated)
      on_exit(fn -> stop_owner(first) end)
      on_exit(fn -> stop_owner(second) end)

      assert_ready(first)
      assert_ready(second)
      Port.command(first, "GO\n")
      Port.command(second, "GO\n")

      results = [{first, await_result(first)}, {second, await_result(second)}]
      assert [{winner, {:won, _}}, {_loser, {:busy, _}}] = sort_results(results)

      assert {:error,
              %Error{code: :invalid_request, message: "cache root is owned by another OS process"}} =
               Cache.new(root, owner: "shared-owner")

      stop_owner(winner)
      assert_exit(winner)

      recovered = start_owner(root, "shared-owner", :immediate)
      assert {:won, _output} = await_result(recovered)
      stop_owner(recovered)
      assert_exit(recovered)
    end
  end

  test "live owner crash releases the native lock without losing cache resources", %{
    tmp_dir: tmp_dir
  } do
    root = Path.join(tmp_dir, "crash-recovery")
    prepared = Path.join([root, "prepared", "retained", "guide.md"])
    owner = start_owner(root, "shared-owner", :immediate, prepared)
    on_exit(fn -> stop_owner(owner) end)

    assert {:won, _output} = await_result(owner)
    assert File.read!(prepared) == "retained"

    contender = start_owner(root, "shared-owner", :immediate)
    assert {:busy, _output} = await_result(contender)
    assert_exit(contender)

    kill_owner(owner)
    assert_exit(owner)

    recovered = start_owner(root, "shared-owner", :immediate)
    assert {:won, _output} = await_result(recovered)
    assert File.read!(prepared) == "retained"
    stop_owner(recovered)
    assert_exit(recovered)
  end

  test "same VM reuses canonical physical root and rejects another logical owner", %{
    tmp_dir: tmp_dir
  } do
    real_root = Path.join(tmp_dir, "physical")
    alias_root = Path.join(tmp_dir, "alias")
    File.mkdir_p!(real_root)
    File.ln_s!(real_root, alias_root)

    assert {:ok, first} = Cache.new(real_root, owner: "consumer-a")
    assert {:ok, reopened} = Cache.new(alias_root, owner: "consumer-a")
    assert first.root == reopened.root

    assert {:error,
            %Error{code: :invalid_request, message: "cache root is owned by another consumer"}} =
             Cache.new(alias_root, owner: "consumer-b")
  end

  test "real and symlink paths share native ownership", %{tmp_dir: tmp_dir} do
    real_root = Path.join(tmp_dir, "physical-cross-process")
    alias_root = Path.join(tmp_dir, "cross-process-alias")
    File.mkdir_p!(real_root)
    File.ln_s!(real_root, alias_root)

    owner = start_owner(real_root, "shared-owner", :immediate)
    on_exit(fn -> stop_owner(owner) end)
    assert {:won, _output} = await_result(owner)

    alias_contender = start_owner(alias_root, "shared-owner", :immediate)
    assert {:busy, _output} = await_result(alias_contender)
    assert_exit(alias_contender)
  end

  test "backend and metadata initialization failures release or never create a handle", %{
    tmp_dir: tmp_dir
  } do
    unavailable_root = Path.join(tmp_dir, "unavailable")
    File.mkdir_p!(unavailable_root)
    unavailable = start_coordinator(UnavailableLock)
    assert {:error, :unavailable} = Ownership.acquire(unavailable, unavailable_root, "owner")
    refute File.exists?(Path.join(unavailable_root, ".owner"))

    metadata_root = Path.join(tmp_dir, "metadata-failure")
    File.mkdir_p!(Path.join(metadata_root, ".owner"))
    coordinator = start_coordinator(NativeLock)

    assert {:error, {:owner_metadata, _reason}} =
             Ownership.acquire(coordinator, metadata_root, "owner")

    File.rmdir!(Path.join(metadata_root, ".owner"))
    assert :ok = Ownership.acquire(coordinator, metadata_root, "owner")
  end

  test "coordinator failure drops its resource and permits a later VM", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "holder-failure")
    File.mkdir_p!(root)
    coordinator = start_coordinator(NativeLock)
    assert :ok = Ownership.acquire(coordinator, root, "owner")

    contender = start_owner(root, "owner", :immediate)
    assert {:busy, _output} = await_result(contender)
    assert_exit(contender)

    monitor = Process.monitor(coordinator)
    Process.unlink(coordinator)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :killed}, @deadline

    recovered = start_owner(root, "owner", :immediate)
    assert {:won, _output} = await_result(recovered)
    stop_owner(recovered)
    assert_exit(recovered)
  end

  test "legacy process marker and unsafe native paths fail closed", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "legacy")
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".process-owner"), "12345")

    assert {:error,
            %Error{
              code: :invalid_request,
              message: "legacy cache ownership requires quiescent migration"
            }} =
             Cache.new(root, owner: "owner")

    assert {:error, :invalid_path} = NativeLock.acquire(<<"invalid", 0, "path">>)
  end

  defp start_coordinator(backend) do
    name = {:global, {__MODULE__, make_ref()}}
    {:ok, pid} = Ownership.start_link(name: name, backend: backend)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp start_owner(root, owner, gate, resource_path \\ nil) do
    elixir = System.find_executable("elixir") || flunk("elixir executable is unavailable")
    ebin = :backplane_skill_protocol |> :code.lib_dir() |> Path.join("ebin")

    expression = """
    {:ok, _coordinator} = Backplane.SkillProtocol.Cache.Ownership.start_link([])
    [root, owner, gate, resource_path] = System.argv()
    if gate == "gated", do: (IO.puts("READY"); IO.read(:line))

    case Backplane.SkillProtocol.Cache.new(root, owner: owner) do
      {:ok, _cache} ->
        if resource_path != "", do: (File.mkdir_p!(Path.dirname(resource_path)); File.write!(resource_path, "retained"))
        IO.puts("WON")
        IO.read(:line)

      {:error, %{message: "cache root is owned by another OS process"}} ->
        IO.puts("BUSY")

      {:error, error} ->
        IO.puts("ERROR:" <> inspect(error))
    end
    """

    Port.open(
      {:spawn_executable, elixir},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "-pa",
          ebin,
          "-e",
          expression,
          "--",
          root,
          owner,
          Atom.to_string(gate),
          resource_path || ""
        ]
      ]
    )
  end

  defp assert_ready(port) do
    assert {:ready, _output} = await_marker(port, ready: "READY")
  end

  defp await_result(port), do: await_marker(port, won: "WON", busy: "BUSY")

  defp await_marker(port, markers, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        case Enum.find(markers, fn {_result, marker} -> String.contains?(output, marker) end) do
          {result, _marker} -> {result, output}
          nil -> await_marker(port, markers, output)
        end

      {^port, {:exit_status, status}} ->
        flunk("cache owner exited with status #{status}: #{output}")
    after
      @deadline -> flunk("cache owner timed out: #{output}")
    end
  end

  defp sort_results(results) do
    Enum.sort_by(results, fn
      {_port, {:won, _output}} -> 0
      {_port, {:busy, _output}} -> 1
    end)
  end

  defp stop_owner(port) do
    if Port.info(port), do: Port.command(port, "STOP\n")
    :ok
  end

  defp kill_owner(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        executable = System.find_executable("kill") || flunk("kill executable is unavailable")
        {_output, 0} = System.cmd(executable, ["-KILL", Integer.to_string(pid)])

      nil ->
        :ok
    end
  end

  defp assert_exit(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @deadline -> flunk("cache owner did not exit")
    end
  end
end
