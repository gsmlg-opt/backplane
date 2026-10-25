defmodule Backplane.AgentRuntime.Tools.LocalCommandBootstrapTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Tools.LocalCommand

  @moduletag :tmp_dir
  unless match?({:unix, :linux}, :os.type()) and File.dir?("/proc/self") do
    @moduletag skip: "local command bootstrap requires Linux /proc"
  end

  test "trusted bootstrap paths reject missing, relative, nonexecutable and nonregular files",
       %{tmp_dir: root} do
    nonexecutable = Path.join(root, "not-executable")
    File.write!(nonexecutable, "#!/bin/sh\nexit 0\n")
    File.chmod!(nonexecutable, 0o600)

    for key <- [:setsid_path, :sh_path, :kill_path],
        value <- [nil, "relative", Path.join(root, "missing"), nonexecutable, root] do
      assert {:error, %Error{class: :validation, details: %{option: ^key}}} =
               LocalCommand.start_link([{:name, nil}, {key, value}])
    end
  end

  test "construction pins default and explicit bootstrap paths across later PATH changes",
       %{tmp_dir: root} do
    # PATH belongs to the whole VM. Exercise hostile PATH changes in a separate
    # BEAM so neither application processes nor concurrent tests can observe it.
    script = """
    alias Backplane.AgentRuntime.{Command, Tools.LocalCommand}
    {:ok, _} = Application.ensure_all_started(:backplane_agent_runtime)
    root = #{inspect(root)}
    real = Map.new([:setsid, :sh, :kill], &{&1, System.find_executable(Atom.to_string(&1))})
    original_path = System.fetch_env!("PATH")
    hostile = Path.join(root, "hostile")
    trusted = Path.join(root, "trusted")
    File.mkdir_p!(hostile)
    File.mkdir_p!(trusted)
    marker = Path.join(root, "hostile-selected")
    trusted_marker = Path.join(root, "trusted-selected")

    for {name, executable} <- real, {directory, selected} <- [{hostile, marker}, {trusted, trusted_marker}] do
      file = Path.join(directory, Atom.to_string(name))
      File.write!(file, "#!" <> real.sh <> "\\nprintf '%s\\\\n' '" <> Atom.to_string(name) <> "' >> '" <> selected <> "'\\nexec '" <> executable <> "' \\\"$@\\\"\\n")
      File.chmod!(file, 0o700)
    end

    exercise = fn backend, label ->
      {:ok, command} = Command.new(%{adapter: LocalCommand, server: backend, allowed_environment: %{}})
      for mode <- [:cancel, :shutdown] do
        workspace = Path.join(root, label <> Atom.to_string(mode))
        File.mkdir_p!(workspace)
        invocation = %{owner_run_id: label <> Atom.to_string(mode), owner_pid: self(), incarnation: 1,
          session_id: System.unique_integer([:positive, :monotonic]), executable: real.sh,
          arguments: ["-c", "IFS= read -r line"], workspace: workspace, environment: %{}}
        {:ok, _job} = Command.start(command, invocation, deadline_limit: 5_000)
        case mode do
          :cancel -> :ok = Command.cancel_confirmed(command, invocation, 1_500)
          :shutdown -> :ok = GenServer.stop(backend)
        end
      end
    end

    {:ok, default} = LocalCommand.start_link(name: nil)
    System.put_env("PATH", hostile)
    exercise.(default, "default")
    false = File.exists?(marker)

    {:ok, explicit} = LocalCommand.start_link(name: nil,
      setsid_path: Path.join(trusted, "setsid"), sh_path: Path.join(trusted, "sh"),
      kill_path: Path.join(trusted, "kill"))
    exercise.(explicit, "explicit")
    false = File.exists?(marker)
    selected = File.read!(trusted_marker) |> String.split()
    true = Enum.all?(["setsid", "sh", "kill"], &(&1 in selected))
    System.put_env("PATH", original_path)
    IO.puts("BOOTSTRAP_PINNING_OK")
    """

    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) |> Enum.map(&List.to_string/1)

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
               env: [{"ERL_FLAGS", "+S 2:2"}],
               stderr_to_stdout: true
             )

    assert output =~ "BOOTSTRAP_PINNING_OK"
  end

  test "32 independent backends confirm concurrent cancellation under default cleanup budgets",
       %{tmp_dir: root} do
    jobs =
      for index <- 1..32 do
        server =
          start_supervised!(
            Supervisor.child_spec({LocalCommand, name: nil}, id: {LocalCommand, index})
          )

        {:ok, command} =
          Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

        workspace = Path.join(root, Integer.to_string(index))
        File.mkdir_p!(workspace)
        invocation = invocation(workspace, "concurrent-#{index}")
        assert {:ok, job} = Command.start(command, invocation, deadline_limit: 10_000)
        {command, invocation, job}
      end

    results =
      Task.async_stream(
        jobs,
        fn {command, invocation, job} ->
          result = Command.cancel_confirmed(command, invocation, 1_500)
          {result, Command.read(command, invocation, job, cursor: 0)}
        end,
        max_concurrency: 32,
        timeout: 3_000
      )
      |> Enum.to_list()

    assert length(results) == 32

    for result <- results do
      assert {:ok, {:ok, {:ok, %{cleanup_status: :confirmed}}}} = result
    end
  end

  test "cleanup watchdog retains phase and timing diagnostics without confirming uncertainty",
       %{tmp_dir: root} do
    reconciler = fn owner, port, token, _group ->
      send(owner, {:cleanup_phase, port, token, :waiting_for_test_host})

      receive do
        :never_sent -> :ok
      end
    end

    server = start_supervised!({LocalCommand, name: nil, cleanup_reconciler: reconciler})

    {:ok, command} =
      Command.new(%{adapter: LocalCommand, server: server, allowed_environment: %{}})

    invocation = invocation(root, "diagnostic")
    assert {:ok, job} = Command.start(command, invocation, deadline_limit: 5_000)

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.cancel_confirmed(command, invocation, 1_500)

    assert {:ok, %{cleanup_status: :uncertain, cleanup_error: error}} =
             Command.read(command, invocation, job, cursor: 0)

    assert error.details.phase == :waiting_for_test_host
    assert error.details.cleanup_timeout_ms == 750
    assert error.details.elapsed_ms >= 750
    assert error.details.phase_elapsed_ms >= 0
  end

  defp invocation(workspace, owner) do
    %{
      owner_run_id: owner,
      owner_pid: self(),
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic]),
      executable: System.find_executable("sh"),
      arguments: ["-c", "IFS= read -r line"],
      workspace: workspace,
      environment: %{}
    }
  end
end
