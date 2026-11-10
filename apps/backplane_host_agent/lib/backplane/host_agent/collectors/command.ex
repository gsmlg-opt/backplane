defmodule Backplane.HostAgent.Collectors.Command do
  @moduledoc """
  Runs an external command with a timeout; the default collector runner.

  Runs in the caller process over a Port. On timeout the OS process is killed,
  not just abandoned. stderr is not merged into the output.
  """

  @default_timeout 5_000

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, :not_found | {:exit, integer()} | :timeout}
  def run(cmd, args, opts \\ []) do
    case System.find_executable(cmd) do
      nil -> {:error, :not_found}
      path -> run_executable(path, args, opts)
    end
  end

  defp run_executable(path, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    port_opts =
      [:binary, :exit_status, args: args] ++
        case Keyword.get(opts, :cd) do
          nil -> []
          dir -> [cd: dir]
        end

    port = Port.open({:spawn_executable, path}, port_opts)
    collect(port, deadline, [])
  rescue
    # spawn failure (e.g. permission denied) is reported as "command not runnable"
    ErlangError -> {:error, {:exit, 127}}
  end

  defp collect(port, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, [acc | data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
