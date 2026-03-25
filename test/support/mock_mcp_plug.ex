defmodule Backplane.Test.MockMcpPlug do
  @moduledoc """
  Mock MCP server plug for testing upstream proxy connections.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    response =
      case request["method"] do
        "initialize" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "protocolVersion" => "2025-03-26",
              "serverInfo" => %{"name" => "mock", "version" => "0.1.0"},
              "capabilities" => %{"tools" => %{"listChanged" => false}}
            }
          }

        "tools/list" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "tools" => [
                %{
                  "name" => "echo",
                  "description" => "Echo back the input",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "message" => %{"type" => "string"}
                    }
                  }
                },
                %{
                  "name" => "greet",
                  "description" => "Greet someone",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{
                      "name" => %{"type" => "string"}
                    }
                  }
                }
              ]
            }
          }

        "tools/call" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{
              "content" => [
                %{"type" => "text", "text" => "mock result"}
              ]
            }
          }

        "ping" ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "result" => %{}
          }

        _ ->
          %{
            "jsonrpc" => "2.0",
            "id" => request["id"],
            "error" => %{"code" => -32_601, "message" => "Method not found"}
          }
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end
end
