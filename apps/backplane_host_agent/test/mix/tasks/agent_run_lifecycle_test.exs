defmodule Mix.Tasks.Agent.RunLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @root Path.expand("../../../../..", __DIR__)

  for signal <- ["TERM", "INT"] do
    test "umbrella runner owns its service and releases it on SIG#{signal}", %{tmp_dir: tmp_dir} do
      config = write_config(tmp_dir)
      first_pid = run_and_stop(@root, config, unquote(signal))
      restarted_pid = run_and_stop(@root, config, "TERM")
      refute restarted_pid == first_pid
    end
  end

  test "direct child-app runner owns its service", %{tmp_dir: tmp_dir} do
    run_and_stop(Path.join(@root, "apps/backplane_host_agent"), write_config(tmp_dir), "TERM")
  end

  for {label, cwd} <- [
        {"umbrella", @root},
        {"child-app", Path.join(@root, "apps/backplane_host_agent")}
      ] do
    test "#{label} runner creates a missing sample and exits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing/host_agent.yaml")
      {port, pid} = start_runner(unquote(cwd), path)

      try do
        assert_receive {^port, {:exit_status, status}}, 60_000
        assert status == 0
        assert File.exists?(path)
        refute File.exists?(lock_path(path))
      after
        cleanup(port, pid, path)
      end
    end
  end

  defp write_config(tmp_dir) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, http_port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    path = Path.join(tmp_dir, "host_agent.yaml")

    File.write!(path, """
    agent:
      host_id: lifecycle-host
      machine_name: lifecycle-test
      hub_url: http://127.0.0.1:1
      token: lifecycle-test-fixture
      work_dir: #{Path.join(tmp_dir, "work")}
      manifest_path: #{Path.join(tmp_dir, "manifest.json")}
      http_bind: 127.0.0.1
      http_port: #{http_port}
    memory:
      enabled: false
    capture:
      enabled: false
    telemetry:
      enabled: false
    targets: []
    """)

    %{path: path, http_port: http_port}
  end

  defp run_and_stop(cwd, config, signal) do
    {port, launcher_pid} = start_runner(cwd, config.path)

    try do
      await_service(port, config, System.monotonic_time(:millisecond) + 60_000, "")

      service_pid = read_service_pid(config.path)
      assert {_, 0} = System.cmd("kill", ["-#{signal}", launcher_pid], stderr_to_stdout: true)
      assert_receive {^port, {:exit_status, _status}}, 5_000

      assert eventually(
               fn -> not listening?(config.http_port) and not alive?(service_pid) end,
               3_000
             ),
             "agent service #{service_pid} survived launcher #{launcher_pid} SIG#{signal}"

      assert service_pid == launcher_pid
      service_pid
    after
      cleanup(port, launcher_pid, config.path)
    end
  end

  defp await_service(port, config, deadline, output) do
    if File.exists?(lock_path(config.path)) and listening?(config.http_port) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("agent did not start its listener: #{output}")
      end

      receive do
        {^port, {:data, data}} ->
          await_service(port, config, deadline, String.slice(output <> data, -8_000, 8_000))

        {^port, {:exit_status, status}} ->
          flunk("agent exited during startup with status #{status}: #{output}")
      after
        25 -> await_service(port, config, deadline, output)
      end
    end
  end

  defp start_runner(cwd, config_path) do
    executable = System.find_executable("mix") || flunk("mix executable unavailable")
    erl_options = System.get_env("ELIXIR_ERL_OPTIONS", "") <> " +B"

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["agent.run"],
        cd: cwd,
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"BACKPLANE_HOST_AGENT_CONFIG", String.to_charlist(config_path)},
          {~c"ELIXIR_ERL_OPTIONS", String.to_charlist(erl_options)}
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, Integer.to_string(pid)}
  end

  defp cleanup(port, launcher_pid, config_path) do
    [read_service_pid(config_path), launcher_pid]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn pid ->
      if alive?(pid) do
        System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)

        unless eventually(fn -> not alive?(pid) end, 5_000) do
          System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
        end
      end
    end)

    if Port.info(port), do: Port.close(port)
  end

  defp read_service_pid(path) do
    case File.read(lock_path(path)) do
      {:ok, contents} -> String.trim(contents)
      {:error, :enoent} -> nil
    end
  end

  defp lock_path(path), do: Path.join(Path.dirname(path), ".#{Path.basename(path)}.pid")

  defp listening?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp alive?(nil), do: false
  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp eventually(predicate, timeout) do
    await(predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp await(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
          {_port, {:data, _output}} -> :ok
        after
          25 -> :ok
        end

        await(predicate, deadline)
    end
  end
end
