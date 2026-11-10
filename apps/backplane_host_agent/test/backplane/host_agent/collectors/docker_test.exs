defmodule Backplane.HostAgent.Collectors.DockerTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Collectors.Docker

  defp line(status, ports) do
    Jason.encode!(%{
      "Names" => "web",
      "Image" => "nginx:1",
      "State" => "running",
      "Status" => status,
      "Ports" => ports
    })
  end

  defp collect(result, test_pid \\ nil) do
    runner = fn cmd, args, _opts ->
      if test_pid, do: send(test_pid, {:ran, cmd, args})
      result
    end

    Docker.collect(%{enabled: true}, %{runner: runner, os: :linux, home: "/h"})
  end

  test "config_key is :docker" do
    assert Docker.config_key() == :docker
  end

  test "parses containers, sorts ports, runs docker ps" do
    out =
      line("Up 2 hours", "0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp") <>
        "\n" <> Jason.encode!(%{"Names" => "db", "Image" => "pg", "State" => "exited", "Ports" => ""}) <> "\n"

    assert [%{collector: "docker", unit: "local", complete: true, items: items}] =
             collect({:ok, out}, self())

    assert_received {:ran, "docker", ["ps", "--format", "{{json .}}"]}

    assert items == [
             %{
               "name" => "web",
               "image" => "nginx:1",
               "state" => "running",
               "ports" => ["0.0.0.0:443->443/tcp", "0.0.0.0:80->80/tcp"]
             },
             %{"name" => "db", "image" => "pg", "state" => "exited", "ports" => []}
           ]
  end

  test "outputs differing only in Status yield identical snapshots" do
    ports = "0.0.0.0:80->80/tcp"
    assert collect({:ok, line("Up 2 hours", ports)}) == collect({:ok, line("Up 3 hours", ports)})
  end

  test "port order does not matter" do
    a = collect({:ok, line("Up", "a:1->1/tcp, b:2->2/tcp")})
    b = collect({:ok, line("Up", "b:2->2/tcp, a:1->1/tcp")})
    assert a == b
  end

  test "no containers is a complete empty snapshot" do
    assert [%{complete: true, items: []}] = collect({:ok, ""})
  end

  test "malformed line is skipped and marks the snapshot partial" do
    assert [%{complete: false, items: [%{"name" => "web"}]}] =
             collect({:ok, "garbage\n" <> line("Up", "")})
  end

  test "unavailable docker yields no snapshot" do
    assert collect({:error, :not_found}) == []
    assert collect({:error, {:exit, 1}}) == []
    assert collect({:error, :timeout}) == []
  end
end
