defmodule Backplane.Integration.MemoryMcpContractTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Memory.Tools
  alias Backplane.Registry.ToolRegistry

  @five_tools ~w(memory::forget memory::get memory::recent memory::remember memory::search)

  setup do
    tool_rows = :ets.tab2list(:backplane_tools)
    ToolRegistry.deregister_managed(Tools.prefix())
    ToolRegistry.register_managed(Tools.prefix(), Tools.tools())

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, tool_rows)
    end)

    {_writer, write_token} =
      Backplane.Fixtures.insert_client(
        name: "memory-contract-writer",
        scopes: ["memory.read", "memory.write"]
      )

    {_reader, read_token} =
      Backplane.Fixtures.insert_client(name: "memory-contract-reader", scopes: ["memory.read"])

    %{write_token: write_token, read_token: read_token}
  end

  test "tools/list exposes exactly the five memory tools", %{write_token: token} do
    names =
      mcp_request("tools/list", nil, auth_token: token)["result"]["tools"]
      |> Enum.map(& &1["name"])
      |> Enum.filter(&String.starts_with?(&1, "memory::"))
      |> Enum.sort()

    assert names == @five_tools
  end

  test "remember then search round-trips over POST /mcp", %{write_token: token} do
    content = "contract round trip #{System.unique_integer([:positive])}"

    remembered =
      call_tool(token, "memory::remember", %{"content" => content, "kind" => "note"})

    assert %{"id" => id, "content" => ^content, "status" => _} = remembered

    found = call_tool(token, "memory::search", %{"query" => content})
    assert Enum.any?(found["results"], &(&1["id"] == id))
  end

  test "read-only clients get a scope error on remember", %{read_token: token} do
    response =
      mcp_request(
        "tools/call",
        %{"name" => "memory::remember", "arguments" => %{"content" => "denied"}},
        auth_token: token
      )

    assert %{"error" => %{"code" => -32_001}} = response
  end

  defp call_tool(token, name, arguments) do
    response =
      mcp_request("tools/call", %{"name" => name, "arguments" => arguments}, auth_token: token)

    assert %{"result" => %{"content" => [%{"type" => "text", "text" => encoded}]} = result} =
             response

    refute result["isError"]
    Jason.decode!(encoded)
  end
end
