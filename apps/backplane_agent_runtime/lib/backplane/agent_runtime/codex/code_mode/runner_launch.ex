defmodule Backplane.AgentRuntime.Codex.CodeMode.RunnerLaunch do
  @moduledoc false

  alias Backplane.AgentRuntime.Codex.CodeMode.{Runner, Worker}
  alias Backplane.AgentRuntime.Error

  @artifact "backplane_code_mode_runner/bin/backplane-code-mode-runner"
  @handshake_limit 4_096
  @boot_timeout 5_000
  @verified_runner {__MODULE__, :verified_runner}

  # Root and child discovery share an immutable installed runner. Cache the last
  # successful ready/cleanup probe against that installation's executable stat.
  # Every actual cell still verifies its own boot before sending JavaScript.
  def verify(configured) do
    with path when is_binary(path) <- executable(configured),
         {:ok, stat} <- File.stat(path, time: :posix) do
      fingerprint = {path, stat.inode, stat.mtime, stat.ctime, stat.size}

      if :persistent_term.get(@verified_runner, nil) == fingerprint or probe(path) do
        :persistent_term.put(@verified_runner, fingerprint)
        {:ok, path}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  def executable(nil) do
    path =
      System.get_env("BACKPLANE_CODE_MODE_RUNNER") ||
        Path.expand("../../" <> @artifact, Application.app_dir(:backplane_agent_runtime))

    executable(path)
  end

  def executable(path) when is_binary(path) do
    if Path.type(path) == :absolute and File.regular?(path),
      do: System.find_executable(path)
  end

  def executable(_path), do: nil

  defp probe(path) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {token, Worker.probe_runner(path)}) end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result == :ok

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        false
    after
      @boot_timeout + 1_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        false
    end
  end

  def open(path) do
    {:ok, Port.open({:spawn_executable, path}, [:binary, :exit_status])}
  rescue
    exception ->
      {:error,
       Error.new(:unsupported_capability, "unable to start the Code Mode runner",
         cause: exception
       )}
  end

  def ready(port, opts) do
    now = System.monotonic_time(:millisecond)
    deadline = now + min(@boot_timeout, Keyword.fetch!(opts, :timeout))

    deadline =
      case Keyword.get(opts, :absolute_deadline) do
        absolute when is_integer(absolute) -> min(deadline, absolute)
        _ -> deadline
      end

    receive_ready(port, deadline, "")
  end

  defp receive_ready(port, deadline, buffer) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(data) + byte_size(buffer) <= @handshake_limit ->
        case :binary.split(buffer <> data, "\n") do
          [partial] -> receive_ready(port, deadline, partial)
          [line, ""] -> validate_ready(line)
          _ -> invalid_ready()
        end

      {^port, {:data, _}} ->
        invalid_ready()

      {^port, {:exit_status, status}} ->
        {:error,
         Error.new(:unsupported_capability, "Code Mode runner exited before its ready handshake",
           details: %{exit_status: status}
         )}

      {:EXIT, ^port, _reason} ->
        invalid_ready()
    after
      remaining -> {:error, Error.new(:timeout, "Code Mode runner ready handshake timed out")}
    end
  end

  defp validate_ready(line) do
    protocol = Runner.protocol_version()

    case JSON.decode(line) do
      {:ok, %{"type" => "ready", "protocol" => ^protocol, "engine" => version}}
      when is_binary(version) and version != "" ->
        :ok

      _ ->
        invalid_ready()
    end
  end

  defp invalid_ready,
    do: {:error, Error.new(:malformed_result, "invalid Code Mode runner ready handshake")}
end
