defmodule Backplane.Integration.MemoryMcpContractTest do
  use Backplane.ConnCase, async: false

  alias Backplane.Memory.Service
  alias Backplane.Registry.ToolRegistry

  setup do
    tool_rows = :ets.tab2list(:backplane_tools)

    setting_rows =
      Map.new(["memory.tools", "services.memory.enabled"], fn key ->
        {key, :ets.lookup(:backplane_settings, key)}
      end)

    :ets.insert(:backplane_settings, {"memory.tools", "core"})
    :ets.insert(:backplane_settings, {"services.memory.enabled", false})
    ToolRegistry.deregister_managed(Service.prefix())
    ToolRegistry.register_managed(Service.prefix(), Service.tools())

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, tool_rows)

      Enum.each(setting_rows, fn
        {key, []} -> :ets.delete(:backplane_settings, key)
        {_key, rows} -> :ets.insert(:backplane_settings, rows)
      end)
    end)

    :ok
  end

  test "tools/list exposes the registered core catalog without output extensions" do
    response = mcp_request("tools/list")

    memory_tools =
      response["result"]["tools"]
      |> Enum.filter(&String.starts_with?(&1["name"], "memory::"))

    assert length(memory_tools) == 31

    assert %{
             "name" => "memory::remember",
             "inputSchema" => %{
               "type" => "object",
               "properties" => properties,
               "required" => ["content", "agent_id", "host_id"]
             }
           } = Enum.find(memory_tools, &(&1["name"] == "memory::remember"))

    assert properties["type"]["default"] == "semantic"
    assert properties["scope"]["default"] == "global"

    for tool <- memory_tools do
      refute Map.has_key?(tool, "outputSchema")
      refute Map.has_key?(tool, "output_schema")
      refute Map.has_key?(tool, "structuredContent")
    end
  end

  test "successful managed calls return JSON text without optional error fields" do
    refute Service.enabled?()

    response =
      mcp_request("tools/call", %{
        "name" => "memory::remember",
        "arguments" => %{
          "content" => "transport contract",
          "agent_id" => "contract-agent",
          "host_id" => "contract-host"
        }
      })

    assert %{
             "result" =>
               %{
                 "content" => [%{"type" => "text", "text" => encoded}]
               } = result
           } = response

    refute Map.has_key?(result, "isError")
    refute Map.has_key?(result, "structuredContent")

    assert {:ok, %{"id" => id, "scope" => "global", "memory_type" => "semantic"}} =
             Jason.decode(encoded)

    assert is_binary(id)
  end

  test "tools/call validates required Memory arguments before dispatch" do
    response =
      mcp_request("tools/call", %{
        "name" => "memory::remember",
        "arguments" => %{"content" => "missing host", "agent_id" => "contract-agent"}
      })

    assert %{"error" => %{"code" => -32_602, "message" => message}} = response
    assert message =~ "Missing required arguments"
    assert message =~ "host_id"
  end

  test "managed handler failures use text content and isError true" do
    response =
      mcp_request("tools/call", %{
        "name" => "memory::forget",
        "arguments" => %{"id" => Ecto.UUID.generate()}
      })

    assert %{
             "result" =>
               %{
                 "content" => [%{"type" => "text", "text" => message}],
                 "isError" => true
               } = result
           } = response

    assert message =~ "memory not found"
    refute Map.has_key?(result, "structuredContent")
  end

  test "deregistered Memory tools are absent and calls return unknown-tool errors" do
    :ok = ToolRegistry.deregister_managed(Service.prefix())

    listed_names =
      mcp_request("tools/list")["result"]["tools"]
      |> Enum.map(& &1["name"])

    refute Enum.any?(listed_names, &String.starts_with?(&1, "memory::"))

    response =
      mcp_request("tools/call", %{
        "name" => "memory::remember",
        "arguments" => %{
          "content" => "disabled",
          "agent_id" => "contract-agent",
          "host_id" => "contract-host"
        }
      })

    assert %{
             "result" => %{
               "content" => [%{"type" => "text", "text" => message}],
               "isError" => true
             }
           } = response

    assert message =~ "Unknown tool: memory::remember"
  end
end
