defmodule Backplane.AgentRuntime.Tools.LocalCommand.Procfs do
  @moduledoc false

  def identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"), do: parse_stat(stat)
  end

  def exact_identity(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {:ok, basic} <- parse_stat(stat),
         [_, rest] <- String.split(stat, ") ", parts: 2),
         fields when length(fields) >= 20 <- String.split(rest),
         {start, ""} <- Integer.parse(Enum.at(fields, 19)) do
      {:ok, Map.put(basic, :start, start)}
    else
      _ -> {:error, :unverified_identity}
    end
  end

  def group_exists?(process_group_id, read_file \\ &File.read/1, list_directory \\ &File.ls/1) do
    # A matching leader proves presence. Its absence never proves that the
    # group is empty: descendants can outlive their leader.
    case group_member?("/proc/#{process_group_id}/stat", process_group_id, read_file) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> scan_group(process_group_id, read_file, list_directory)
      {:error, _} = error -> error
    end
  end

  defp scan_group(process_group_id, read_file, list_directory) do
    case list_directory.("/proc") do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, false}, fn entry, {:ok, false} ->
          case Integer.parse(entry) do
            {pid, ""} when pid > 0 ->
              case group_member?("/proc/#{entry}/stat", process_group_id, read_file) do
                {:ok, false} -> {:cont, {:ok, false}}
                result -> {:halt, result}
              end

            _ ->
              {:cont, {:ok, false}}
          end
        end)

      {:error, reason} ->
        {:error, {:proc_directory_unreadable, reason}}
    end
  end

  defp group_member?(path, process_group_id, read_file) do
    case read_file.(path) do
      {:ok, stat} ->
        case parse_stat(stat) do
          {:ok, %{group: group}} -> {:ok, group == process_group_id}
          :error -> {:error, {:malformed_proc_stat, path}}
        end

      {:error, reason} when reason in [:enoent, :esrch] ->
        {:ok, false}

      {:error, reason} ->
        {:error, {:proc_stat_unreadable, path, reason}}
    end
  end

  defp parse_stat(stat) do
    case String.split(stat, ") ", parts: 2) do
      [_identity, rest] ->
        case String.split(rest) do
          [_state, parent, group, session | _rest] ->
            with {parent, ""} <- Integer.parse(parent),
                 {group, ""} <- Integer.parse(group),
                 {session, ""} <- Integer.parse(session) do
              {:ok, %{parent: parent, group: group, session: session}}
            else
              _other -> :error
            end

          _other ->
            :error
        end

      _other ->
        :error
    end
  end
end
