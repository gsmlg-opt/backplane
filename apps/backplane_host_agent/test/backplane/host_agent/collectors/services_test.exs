defmodule Backplane.HostAgent.Collectors.ServicesTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Collectors.Services

  @systemd """
  cron.service      loaded active running Regular background program processing daemon
  ssh.service       loaded active running OpenBSD Secure Shell server
  """

  defp launchd(pid1, pid2) do
    """
    PID\tStatus\tLabel
    #{pid1}\t0\tcom.apple.Finder
    #{pid2}\t0\tcom.example.agent
    -\t78\torg.other.job
    """
  end

  defp collect(os, result, test_pid \\ nil) do
    runner = fn cmd, args, _opts ->
      if test_pid, do: send(test_pid, {:ran, cmd, args})
      result
    end

    Services.collect(%{enabled: true}, %{runner: runner, os: os, home: "/h"})
  end

  test "config_key is :services" do
    assert Services.config_key() == :services
  end

  test "parses systemd units on linux" do
    assert [%{collector: "systemd", unit: "local", complete: true, items: items}] =
             collect(:linux, {:ok, @systemd}, self())

    assert_received {:ran, "systemctl",
                     [
                       "list-units",
                       "--type=service",
                       "--state=running",
                       "--no-legend",
                       "--plain",
                       "--no-pager"
                     ]}

    assert items == [
             %{
               "name" => "cron.service",
               "description" => "Regular background program processing daemon"
             },
             %{"name" => "ssh.service", "description" => "OpenBSD Secure Shell server"}
           ]
  end

  test "short systemd line is skipped and marks partial" do
    assert [%{complete: false, items: [%{"name" => "cron.service"}]}] =
             collect(:linux, {:ok, "bad line\ncron.service loaded active running Cron\n"})
  end

  test "parses launchd labels on darwin, dropping com.apple.*" do
    assert [%{collector: "launchd", unit: "local", complete: true, items: items}] =
             collect(:darwin, {:ok, launchd("123", "-")}, self())

    assert_received {:ran, "launchctl", ["list"]}
    assert items == [%{"label" => "com.example.agent"}, %{"label" => "org.other.job"}]
  end

  test "launchd outputs differing only in PIDs yield identical snapshots" do
    assert collect(:darwin, {:ok, launchd("123", "456")}) ==
             collect(:darwin, {:ok, launchd("-", "999")})
  end

  test "short launchd line is skipped and marks partial" do
    out = "PID\tStatus\tLabel\n1\t0\tcom.example.a\njunk\n"
    assert [%{complete: false, items: [%{"label" => "com.example.a"}]}] = collect(:darwin, {:ok, out})
  end

  test "other os yields nothing and runs nothing" do
    assert collect(:other, {:ok, "x"}) == []
  end

  test "unavailable binaries or failures yield no snapshot" do
    for os <- [:linux, :darwin], r <- [{:error, :not_found}, {:error, {:exit, 1}}, {:error, :timeout}] do
      assert collect(os, r) == []
    end
  end
end
