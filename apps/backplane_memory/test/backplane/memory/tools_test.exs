defmodule Backplane.Memory.ToolsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{ServiceRegistration, Tools}
  alias Backplane.Registry.ToolRegistry

  defp call(short, args, auth \\ %{kind: :open, client_id: nil, principal_metadata: %{}}) do
    tool = Enum.find(Tools.tools(), &(&1.name == "memory::" <> short))
    tool.handler.(args, auth)
  end

  test "tools/0 exposes exactly the five names" do
    assert Enum.sort(Enum.map(Tools.tools(), & &1.name)) ==
             Enum.sort(~w(memory::search memory::get memory::recent memory::remember memory::forget))

    for tool <- Tools.tools(), do: assert(is_function(tool.handler, 2))
    assert Tools.tools() |> Enum.map(& &1.input_schema) |> Enum.all?(&is_map/1)
  end

  test "remember stamps client and channel host" do
    auth = %{kind: :client_token, client_id: "c1", principal_metadata: %{"host_id" => "h1"}}
    assert {:ok, r} = call("remember", %{"content" => "stamped", "host" => "spoofed"}, auth)
    assert r["provenance"]["host"] == "h1"
    assert r["provenance"]["client"] == "c1"
    assert r["provenance"]["writer"] == "agent"
  end

  test "remember without channel host uses arg host" do
    assert {:ok, r} = call("remember", %{"content" => "arghost", "host" => "web-1", "agent" => "a"})
    assert r["provenance"]["host"] == "web-1"
    assert r["provenance"]["agent"] == "a"
    assert r["provenance"]["client"] == nil
  end

  test "remember accepts an optional ISO 8601 observed_at" do
    assert {:ok, r} =
             call("remember", %{"content" => "late", "observed_at" => "2026-01-02T03:04:05Z"})

    assert {:ok, at, _} = DateTime.from_iso8601(r["observed_at"] |> to_string())
    assert DateTime.compare(at, ~U[2026-01-02 03:04:05Z]) == :eq

    assert {:error, "invalid: observed_at"} =
             call("remember", %{"content" => "x", "observed_at" => "yesterday"})

    assert {:error, "invalid: observed_at"} =
             call("remember", %{"content" => "x", "observed_at" => 123})
  end

  test "remember reports invalid attrs" do
    assert {:error, "invalid: " <> _} = call("remember", %{"content" => "x", "kind" => "bogus"})
  end

  test "forget requires reason" do
    assert {:ok, r} = call("remember", %{"content" => "to forget"})
    assert {:error, msg} = call("forget", %{"id" => r["id"]})
    assert msg =~ "reason"
    assert {:ok, %{"status" => "forgotten"}} = call("forget", %{"id" => r["id"], "reason" => "no"})
  end

  test "search returns results with provenance" do
    assert {:ok, _} = call("remember", %{"content" => "zebrafish habitat notes", "host" => "h9"})
    assert {:ok, %{"results" => [hit | _]}} = call("search", %{"query" => "zebrafish"})
    assert hit["provenance"]["host"] == "h9"
  end

  test "search and recent turn invalid filters into errors" do
    assert {:error, "invalid: " <> _} = call("search", %{"query" => "x", "limit" => 0})
    assert {:error, "invalid: " <> _} = call("search", %{"query" => "x", "since" => "nope"})
    assert {:error, "invalid: " <> _} = call("recent", %{"limit" => -1})
  end

  test "get returns record with history; unknown id is not_found" do
    assert {:ok, r} = call("remember", %{"content" => "getme"})
    assert {:ok, %{"record" => %{"id" => id}, "history" => []}} = call("get", %{"id" => r["id"]})
    assert id == r["id"]
    assert {:error, "not_found"} = call("get", %{"id" => Ecto.UUID.generate()})
  end

  test "recent returns worklog records" do
    assert {:ok, _} = call("remember", %{"content" => "did stuff", "kind" => "worklog"})
    assert {:ok, _} = call("remember", %{"content" => "plain note", "kind" => "note"})
    assert {:ok, %{"results" => results}} = call("recent", %{})
    assert results != []
    assert Enum.all?(results, &(&1["kind"] == "worklog"))
  end

  test "registration: with no settings row, memory tools are registered" do
    supervisor = Process.whereis(Backplane.Memory.Supervisor)
    :ok = Supervisor.terminate_child(supervisor, ServiceRegistration)
    on_exit(fn -> Supervisor.restart_child(supervisor, ServiceRegistration) end)

    assert :not_found = ToolRegistry.resolve("memory::search")
    assert {:ok, pid} = Supervisor.restart_child(supervisor, ServiceRegistration)
    :sys.get_state(pid)
    assert {:managed, _} = ToolRegistry.resolve("memory::search")
  end
end
