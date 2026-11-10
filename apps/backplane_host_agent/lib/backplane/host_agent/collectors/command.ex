defmodule Backplane.HostAgent.Collectors.Command do
  @moduledoc "Runs an external command with a timeout; the default collector runner."

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
    cmd_opts = opts |> Keyword.take([:cd, :env]) |> Keyword.put(:stderr_to_stdout, false)
    task = Task.async(fn -> System.cmd(path, args, cmd_opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {_output, status}} -> {:error, {:exit, status}}
      {:exit, _reason} -> {:error, {:exit, -1}}
      nil -> {:error, :timeout}
    end
  end
end
