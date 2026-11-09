defmodule Backplane.AgentRuntime.Codex.CodeMode.ProcessObserver do
  @moduledoc false
  # Platform boundary for observing the Deno OS process owned by a Code Mode worker.
  # Linux reads procfs; macOS uses the packaged native session helper's `--process`
  # probe (built by `mix backplane.command.build`). Identities are `%{starttime, state}`
  # where `state` is "Z"/"X" for an exited, unreaped process.

  @helper "priv/bin/backplane-local-command-session"

  @spec capability() :: :verified | {:unsupported, atom()}
  def capability do
    cond do
      not is_binary(System.find_executable("kill")) ->
        {:unsupported, :kill_unavailable}

      :os.type() == {:unix, :linux} ->
        if File.dir?("/proc"), do: :verified, else: {:unsupported, :proc_unavailable}

      :os.type() == {:unix, :darwin} ->
        darwin_capability()

      true ->
        {:unsupported, :process_identity_unavailable}
    end
  end

  @spec identity(pos_integer()) ::
          {:ok, %{state: String.t(), starttime: String.t()}} | {:error, term()}
  def identity(pid) do
    case :os.type() do
      {:unix, :darwin} -> helper_identity(pid)
      _ -> proc_identity(pid)
    end
  end

  defp darwin_capability do
    with {:ok, helper} <- helper_path(),
         {:ok, _identity} <- helper_identity(helper, System.pid() |> String.to_integer()) do
      :verified
    else
      _ -> {:unsupported, :native_helper_unavailable}
    end
  end

  defp helper_path do
    path = Application.app_dir(:backplane_agent_runtime, @helper)

    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> {:ok, path}
      _ -> {:error, :native_helper_unavailable}
    end
  end

  defp helper_identity(pid) do
    case helper_path() do
      {:ok, helper} -> helper_identity(helper, pid)
      error -> error
    end
  end

  defp helper_identity(helper, pid) do
    case System.cmd(helper, ["--process", Integer.to_string(pid)], stderr_to_stdout: true) do
      {"absent\n", 0} ->
        {:error, :esrch}

      {output, 0} ->
        case String.split(output) do
          [starttime, state] when state in ["R", "Z"] ->
            {:ok, %{state: state, starttime: starttime}}

          _ ->
            {:error, :malformed_process_probe}
        end

      _ ->
        {:error, :unverified_process_probe}
    end
  rescue
    _ -> {:error, :unverified_process_probe}
  end

  defp proc_identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_, fields] <- Regex.run(~r/^\d+ \(.*\) (.+)$/s, stat),
         parts <- String.split(fields),
         state when is_binary(state) <- Enum.at(parts, 0),
         starttime when is_binary(starttime) <- Enum.at(parts, 19) do
      {:ok, %{state: state, starttime: starttime}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_proc_stat}
    end
  end
end
