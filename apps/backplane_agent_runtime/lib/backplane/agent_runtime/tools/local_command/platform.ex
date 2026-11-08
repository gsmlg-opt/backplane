defmodule Backplane.AgentRuntime.Tools.LocalCommand.Platform do
  @moduledoc false
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools.LocalCommand.Procfs

  def capability(helper) do
    case System.cmd(helper, ["--probe"], stderr_to_stdout: true) do
      {"BACKPLANE_SESSION 1\n", 0} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def confirm_launcher_exit(pid, %{session_helper: _} = paths) when is_integer(pid) do
    await_launcher_exit(pid, paths, System.monotonic_time(:millisecond) + 150)
  end

  def confirm_launcher_exit(_pid, %{session_helper: _}),
    do: {:error, Error.new(:unknown_outcome, "native session helper identity is unavailable")}

  def confirm_launcher_exit(_pid, _paths), do: :ok

  defp await_launcher_exit(pid, paths, deadline) do
    cond do
      not present_or_uncertain?(pid, paths) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, Error.new(:unknown_outcome, "native session helper exit is unconfirmed")}

      true ->
        Process.sleep(10)
        await_launcher_exit(pid, paths, deadline)
    end
  end

  def identity(pid, %{session_helper: helper}) do
    with {text, 0} <- System.cmd(helper, ["--identity", to_string(pid)]),
         [parent, group, session, start] <- String.split(text),
         {parent, ""} <- Integer.parse(parent),
         {group, ""} <- Integer.parse(group),
         {session, ""} <- Integer.parse(session) do
      {:ok, %{parent: parent, group: group, session: session, start: start}}
    else
      _ -> {:error, :unverified_identity}
    end
  rescue
    _ -> {:error, :unverified_identity}
  end

  def identity(pid, _paths), do: Procfs.identity(pid)

  def group_exists?(pid, %{session_helper: helper}), do: probe(helper, "--group-exists", pid)
  def group_exists?(pid, _paths), do: Procfs.group_exists?(pid)

  # Errors and reused PIDs retain obligations. Only authoritative absence retires them.
  def present_or_uncertain?(pid, %{session_helper: helper}) do
    probe(helper, "--alive", pid) != {:ok, false}
  end

  def present_or_uncertain?(pid, _paths), do: File.exists?("/proc/#{pid}")

  def signal(pid, signal, %{session_helper: helper}) do
    System.cmd(helper, [if(signal == "-TERM", do: "--term", else: "--kill"), to_string(pid)],
      stderr_to_stdout: true
    )
  end

  def signal(pid, signal, %{kill: kill_path}) do
    System.cmd(kill_path, [signal, "--", "-#{pid}"], stderr_to_stdout: true)
  end

  def probe(helper, mode, pid) do
    case System.cmd(helper, [mode, to_string(pid)], stderr_to_stdout: true) do
      {"present\n", 0} -> {:ok, true}
      {"absent\n", 0} -> {:ok, false}
      _ -> {:error, :unverified_process_probe}
    end
  rescue
    _ -> {:error, :unverified_process_probe}
  end
end
