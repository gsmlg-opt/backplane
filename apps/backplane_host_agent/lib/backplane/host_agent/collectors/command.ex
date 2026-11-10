defmodule Backplane.HostAgent.Collectors.Command do
  @moduledoc """
  Runs an external command with a timeout; the default collector runner.

  Runs in the caller process over a Port. On timeout the OS process is killed,
  not just abandoned. stderr is discarded (`/bin/sh` redirects it, then `exec`s
  the command so the port's OS pid is the command itself).

  With `output_on_error: true` a non-zero exit returns `{:error, {:exit, status, output}}`
  so callers can tell an empty failure from one that printed something.
  """

  @default_timeout 5_000

  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()}
          | {:error, :not_found | {:exit, integer()} | {:exit, integer(), String.t()} | :timeout}
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
      [:binary, :exit_status, args: ["-c", ~s(exec "$0" "$@" 2>/dev/null), path | args]] ++
        case Keyword.get(opts, :cd) do
          nil -> []
          dir -> [cd: dir]
        end

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
    collect(port, deadline, Keyword.get(opts, :output_on_error, false), [])
  rescue
    # spawn failure (e.g. permission denied) is reported as "command not runnable"
    ErlangError -> {:error, {:exit, 127}}
  end

  defp collect(port, deadline, output_on_error?, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, output_on_error?, [acc | data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} when output_on_error? ->
        {:error, {:exit, status, IO.iodata_to_binary(acc)}}

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
