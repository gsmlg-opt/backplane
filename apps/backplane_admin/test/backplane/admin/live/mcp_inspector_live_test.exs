defmodule Backplane.Admin.McpInspectorLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Registry.Tool

  setup do
    tools = :ets.tab2list(:backplane_tools)
    :ets.delete_all_objects(:backplane_tools)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
      :ets.insert(:backplane_tools, tools)
    end)

    :ok
  end

  test "internal source list merges path-like upstream prefixes", %{conn: conn} do
    insert_tool(%Tool{
      name: "/github::search",
      description: "Search repositories",
      input_schema: %{},
      origin: {:upstream, "/github"},
      original_name: "search"
    })

    insert_tool(%Tool{
      name: "github::create_issue",
      description: "Create issues",
      input_schema: %{},
      origin: {:upstream, "github"},
      original_name: "create_issue"
    })

    {:ok, _view, html} = live(conn, "/mcp/inspector/internal")

    refute html =~ "/github:: (upstream)"
    assert html =~ "github:: (upstream)"
  end

  test "stdio connect reports timeout when process never replies", %{conn: conn} do
    sleep = System.find_executable("sleep") || raise "sleep executable not found"
    previous_timeout = Application.get_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms)
    Application.put_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms, 20)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms)
      else
        Application.put_env(:backplane_admin, :mcp_inspector_stdio_timeout_ms, previous_timeout)
      end
    end)

    {:ok, view, _html} = live(conn, "/mcp/inspector")

    render_change(view, "update_config", %{
      "transport" => "stdio",
      "command" => sleep,
      "args" => "2",
      "env" => ""
    })

    render_click(view, "connect")
    Process.sleep(50)

    assert render(view) =~ "Timed out waiting for stdio initialize response"
  end

  test "HTTP connect preserves the negotiated session for follow-up requests", %{conn: conn} do
    bypass = Bypass.open()
    test_pid = self()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      method = request["method"]

      send(test_pid, {
        :mcp_request,
        method,
        request,
        Plug.Conn.get_req_header(conn, "mcp-session-id"),
        Plug.Conn.get_req_header(conn, "mcp-protocol-version")
      })

      case method do
        "initialize" ->
          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-123")
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "protocolVersion" => "2025-11-25",
                "capabilities" => %{},
                "serverInfo" => %{"name" => "stateful-test", "version" => "1.0"}
              }
            })
          )

        "notifications/initialized" ->
          Plug.Conn.resp(conn, 202, "")

        "tools/list" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "result" => %{
                "tools" => [
                  %{
                    "name" => "echo",
                    "description" => "Echo input",
                    "inputSchema" => %{"type" => "object"}
                  }
                ]
              }
            })
          )

        "tools/call" ->
          json_response(conn, request, %{"content" => []})

        "ping" ->
          json_response(conn, request, %{})
      end
    end)

    {:ok, view, _html} = live(conn, "/mcp/inspector")

    render_change(view, "update_config", %{
      "transport" => "http",
      "url" => "http://localhost:#{bypass.port}/mcp",
      "auth_scheme" => "none",
      "credential" => ""
    })

    render_click(view, "connect")

    assert_receive {:mcp_request, "initialize", _request, [], []}

    assert_receive {:mcp_request, "notifications/initialized", notification, ["session-123"],
                    ["2025-11-25"]}

    refute Map.has_key?(notification, "id")

    render_click(view, "list_tools")

    assert_receive {:mcp_request, "tools/list", _request, ["session-123"], ["2025-11-25"]}

    render_click(view, "ping")

    assert_receive {:mcp_request, "ping", _request, ["session-123"], ["2025-11-25"]}

    render_change(view, "update_tool_args", %{"tool_name" => "echo", "tool_args" => "{}"})
    render_click(view, "call_tool", %{"tool_name" => "echo"})

    assert_receive {:mcp_request, "tools/call", _request, ["session-123"], ["2025-11-25"]}

    render_click(view, "disconnect")
    render_click(view, "connect")

    assert_receive {:mcp_request, "initialize", _request, [], []}

    assert_receive {:mcp_request, "notifications/initialized", _request, ["session-123"],
                    _version}

    render_change(view, "update_config", %{
      "transport" => "http",
      "url" => "http://localhost:#{bypass.port}/mcp?changed=true"
    })

    render_click(view, "connect")

    assert_receive {:mcp_request, "initialize", _request, [], []}
  end

  defp json_response(conn, request, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => result
      })
    )
  end

  defp insert_tool(%Tool{} = tool) do
    :ets.insert(:backplane_tools, {tool.name, tool})
  end
end
