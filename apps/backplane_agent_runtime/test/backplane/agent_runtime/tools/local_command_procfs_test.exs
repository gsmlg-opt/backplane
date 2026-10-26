defmodule Backplane.AgentRuntime.Tools.LocalCommandProcfsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Tools.LocalCommand.Procfs

  test "an ESRCH leader still requires scanning for surviving group members" do
    stats = %{
      "/proc/41/stat" => {:error, :esrch},
      "/proc/42/stat" => {:ok, stat(42, 41)}
    }

    assert {:ok, true} = scan(41, stats, ["41", "42"])
  end

  test "an ESRCH entry does not hide a later surviving group member" do
    stats = %{
      "/proc/41/stat" => {:error, :enoent},
      "/proc/42/stat" => {:error, :esrch},
      "/proc/43/stat" => {:ok, stat(43, 41)}
    }

    assert {:ok, true} = scan(41, stats, ["42", "43"])
  end

  test "ESRCH entries confirm absence only after the complete scan" do
    stats = %{
      "/proc/41/stat" => {:error, :esrch},
      "/proc/42/stat" => {:error, :esrch},
      "/proc/43/stat" => {:ok, stat(43, 99)}
    }

    assert {:ok, false} = scan(41, stats, ["self", "0", "42", "43"])
  end

  test "ENOENT entries keep their vanished-entry behavior" do
    stats = %{
      "/proc/41/stat" => {:error, :enoent},
      "/proc/42/stat" => {:error, :enoent},
      "/proc/43/stat" => {:ok, stat(43, 99)}
    }

    assert {:ok, false} = scan(41, stats, ["self", "0", "42", "43"])
  end

  test "a matching leader proves presence without listing procfs" do
    read = fn "/proc/41/stat" -> {:ok, stat(41, 41)} end
    list = fn _ -> flunk("a matching leader already proves presence") end

    assert {:ok, true} = Procfs.group_exists?(41, read, list)
  end

  test "an unreadable leader preserves the actual read error" do
    read = fn "/proc/41/stat" -> {:error, :eacces} end
    list = fn _ -> flunk("a read error cannot establish leader absence") end

    assert {:error, {:proc_stat_unreadable, "/proc/41/stat", :eacces}} =
             Procfs.group_exists?(41, read, list)
  end

  test "an unreadable scanned entry keeps cleanup unconfirmed" do
    stats = %{
      "/proc/41/stat" => {:error, :enoent},
      "/proc/42/stat" => {:error, :eio}
    }

    assert {:error, {:proc_stat_unreadable, "/proc/42/stat", :eio}} =
             scan(41, stats, ["42"])
  end

  test "an unreadable proc directory keeps cleanup unconfirmed" do
    read = fn "/proc/41/stat" -> {:error, :enoent} end
    list = fn "/proc" -> {:error, :eacces} end

    assert {:error, {:proc_directory_unreadable, :eacces}} =
             Procfs.group_exists?(41, read, list)
  end

  test "malformed stat data remains an error" do
    read = fn "/proc/41/stat" -> {:ok, "malformed stat"} end
    list = fn _ -> flunk("malformed stat cannot establish leader absence") end

    assert {:error, {:malformed_proc_stat, "/proc/41/stat"}} =
             Procfs.group_exists?(41, read, list)
  end

  defp scan(group, stats, entries) do
    read = &Map.fetch!(stats, &1)
    list = fn "/proc" -> {:ok, entries} end
    Procfs.group_exists?(group, read, list)
  end

  defp stat(pid, group), do: "#{pid} (fixture) S 1 #{group} #{group} 0 0 0\n"
end
