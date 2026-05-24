defmodule Backplane.HostAgent.RunLock do
  @moduledoc """
  PID-file guard for a single host-agent runner per config file.
  """

  @type lock :: %{path: String.t(), pid: String.t()}

  @doc "Acquire a PID-file lock for the given config path."
  @spec acquire(Path.t()) ::
          {:ok, lock()} | {:error, {:already_running, String.t(), Path.t()}} | {:error, term()}
  def acquire(config_path) do
    config_path
    |> path_for()
    |> write_lock(current_pid())
  end

  @doc "Release a lock previously returned by `acquire/1`."
  @spec release(lock()) :: :ok
  def release(%{path: path, pid: pid}) do
    case File.read(path) do
      {:ok, contents} ->
        if parse_pid(contents) == pid do
          File.rm(path)
        else
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @doc "Returns the lock-file path for a config path."
  @spec path_for(Path.t()) :: Path.t()
  def path_for(config_path) do
    Path.join(Path.dirname(config_path), ".#{Path.basename(config_path)}.pid")
  end

  defp write_lock(path, pid) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, pid <> "\n", [:write, :exclusive]) do
      :ok ->
        {:ok, %{path: path, pid: pid}}

      {:error, :eexist} ->
        handle_existing_lock(path, pid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_existing_lock(path, pid) do
    with {:ok, contents} <- File.read(path),
         existing_pid when is_binary(existing_pid) and existing_pid != "" <- parse_pid(contents),
         true <- pid_alive?(existing_pid) do
      {:error, {:already_running, existing_pid, path}}
    else
      _stale_or_missing ->
        File.rm(path)
        write_lock(path, pid)
    end
  end

  defp parse_pid(contents) do
    contents
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp current_pid do
    :os.getpid()
    |> to_string()
    |> String.trim()
  end

  defp pid_alive?(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
