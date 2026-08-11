defmodule Backplane.McpProtocol.Client.RootsNotificationTest do
  use Backplane.McpProtocol.MCP.Case, async: false

  import Mox

  alias Backplane.McpProtocol.Client

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    test_pid = self()

    Mox.stub_with(Backplane.McpProtocol.MockTransport, MockTransport)

    Mox.stub(Backplane.McpProtocol.MockTransport, :send_message, fn _, message, _ ->
      send(test_pid, {:mcp_send, message})
      :ok
    end)

    :ok
  end

  test "modern root mutations stay local without legacy list-changed notifications" do
    client = start_client(:auto, "ModernRootsClient")
    allow(Backplane.McpProtocol.MockTransport, self(), client)
    negotiate_modern(client)

    assert :ok = Client.add_root(client, "file:///modern", "Modern")
    assert [%{uri: "file:///modern", name: "Modern"}] = Client.list_roots(client)

    assert :ok = Client.remove_root(client, "file:///modern")
    assert [] = Client.list_roots(client)

    assert :ok = Client.add_root(client, "file:///modern")
    assert :ok = Client.clear_roots(client)
    assert [] = Client.list_roots(client)

    refute_receive {:mcp_send, _legacy_roots_notification}, 100
  end

  test "legacy root mutations keep sending list-changed notifications" do
    client = start_client("2025-03-26", "LegacyRootsClient")
    allow(Backplane.McpProtocol.MockTransport, self(), client)
    initialize_client(client)
    flush_mcp_sends()

    assert :ok = Client.add_root(client, "file:///legacy", "Legacy")
    assert_roots_list_changed()

    assert :ok = Client.remove_root(client, "file:///legacy")
    assert_roots_list_changed()

    assert :ok = Client.add_root(client, "file:///legacy")
    assert_roots_list_changed()

    assert :ok = Client.clear_roots(client)
    assert_roots_list_changed()
  end

  defp negotiate_modern(client) do
    GenServer.cast(client, :negotiate)
    discovery_id = get_request_id(client, "server/discover")

    send_response(client, %{
      "jsonrpc" => "2.0",
      "id" => discovery_id,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{},
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{
            "name" => "ModernServer",
            "version" => "1.0.0"
          }
        }
      }
    })

    assert :ok = Client.await_ready(client, timeout: 1_000)
    flush_mcp_sends()
  end

  defp assert_roots_list_changed do
    assert_receive {:mcp_send, encoded_notification}, 500

    assert %{
             "jsonrpc" => "2.0",
             "method" => "notifications/roots/list_changed",
             "params" => %{}
           } = JSON.decode!(encoded_notification)
  end

  defp start_client(protocol_version, name) do
    start_supervised!(%{
      id: {Client, name},
      start:
        {Client, :start_link_server,
         [
           [
             transport: [layer: Backplane.McpProtocol.MockTransport, name: MockTransport],
             client_info: %{"name" => name, "version" => "1.0.0"},
             capabilities: %{"roots" => %{"listChanged" => true}},
             protocol_version: protocol_version
           ]
         ]},
      restart: :temporary
    })
  end
end
