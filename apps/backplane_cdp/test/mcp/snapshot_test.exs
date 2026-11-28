defmodule Backplane.CDP.MCP.SnapshotTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP.MCP.Snapshot

  @nodes [
    %{
      "nodeId" => "1",
      "backendDOMNodeId" => 1,
      "role" => %{"value" => "RootWebArea"},
      "name" => %{"value" => "Form"},
      "childIds" => ["2"]
    },
    %{
      "nodeId" => "2",
      "parentId" => "1",
      "backendDOMNodeId" => 2,
      "role" => %{"value" => "textbox"},
      "name" => %{"value" => "Email"},
      "value" => %{"value" => "hello@example.org"},
      "properties" => [%{"name" => "focused", "value" => %{"value" => true}}]
    }
  ]

  test "formats accessibility nodes and preserves UIDs within a document" do
    {text, snapshot} = Snapshot.render(@nodes, "loader-1", nil, false)
    uid = snapshot.by_backend[2]
    assert text =~ "uid=#{uid} textbox \"Email\" value=\"hello@example.org\" focused"
    assert {:ok, 2} = Snapshot.backend("page-1", %{snapshots: %{"page-1" => snapshot}}, uid)

    assert {:error, _} =
             Snapshot.backend("other-page", %{snapshots: %{"page-1" => snapshot}}, uid)

    {_text, repeated} = Snapshot.render(@nodes, "loader-1", snapshot, false)
    assert repeated.by_backend == snapshot.by_backend

    {_text, navigated} = Snapshot.render(@nodes, "loader-2", snapshot, false)
    refute navigated.by_backend[2] == uid
    assert {:error, _} = Snapshot.backend("page-1", %{snapshots: %{"page-1" => navigated}}, uid)
  end

  test "verbose includes ignored layout nodes" do
    ignored = %{
      "nodeId" => "3",
      "backendDOMNodeId" => 3,
      "ignored" => true,
      "role" => %{"value" => "none"}
    }

    {normal, _} = Snapshot.render([ignored], "loader", nil, false)
    {verbose, _} = Snapshot.render([ignored], "loader", nil, true)
    assert normal == ""
    assert verbose =~ "ignored"
  end
end
