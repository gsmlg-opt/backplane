defmodule Backplane.Test.MockSseHttpPlug do
  @moduledoc "Mock MCP server supporting Streamable HTTP SSE responses."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = read_body(conn)
    request = Jason.decode!(body)
    response = build_response(request)
    accept = get_req_header(conn, "accept") |> List.first("")

    if String.contains?(accept, "text/event-stream") do
      sse_body = "event: message\ndata: #{Jason.encode!(response)}\n\n"

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, sse_body)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response))
    end
  end

  defp build_response(request) do
    case request["method"] do
      "initialize" ->
        %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{
            "protocolVersion" => "2025-03-26",
            "serverInfo" => %{"name" => "mock-sse", "version" => "0.1.0"},
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
                "description" => "Echo",
                "inputSchema" => %{
                  "type" => "object",
                  "properties" => %{"message" => %{"type" => "string"}}
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
            "content" => [%{"type" => "text", "text" => "sse mock result"}]
          }
        }

      "ping" ->
        %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}}

      _ ->
        %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "error" => %{"code" => -32601, "message" => "Method not found"}
        }
    end
  end
end
