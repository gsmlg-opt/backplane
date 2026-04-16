defmodule Backplane.Test.MockSseMcpServer do
  @moduledoc "Mock legacy HTTP+SSE MCP server for testing."

  defmodule Router do
    use Plug.Router
    plug :match
    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :dispatch

    get "/sse" do
      session_id = System.unique_integer([:positive])
      endpoint_url = "/message?sessionId=#{session_id}"

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, "event: endpoint\ndata: #{endpoint_url}\n\n")

      Backplane.Test.MockSseMcpServer.register_session(session_id, self())

      sse_loop(conn)
    end

    post "/message" do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      session_id =
        conn.query_params["sessionId"]
        |> String.to_integer()

      response = Backplane.Test.MockSseMcpServer.build_response(request)
      Backplane.Test.MockSseMcpServer.push_event(session_id, response)

      conn |> send_resp(202, "")
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end

    defp sse_loop(conn) do
      receive do
        {:sse_push, data} ->
          case chunk(conn, "event: message\ndata: #{Jason.encode!(data)}\n\n") do
            {:ok, conn} -> sse_loop(conn)
            {:error, _} -> conn
          end

        :close ->
          conn
      after
        30_000 -> conn
      end
    end
  end

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def register_session(session_id, pid) do
    Agent.update(__MODULE__, &Map.put(&1, session_id, pid))
  end

  def push_event(session_id, data) do
    pid = Agent.get(__MODULE__, &Map.get(&1, session_id))
    if pid, do: send(pid, {:sse_push, data})
  end

  def close_session(session_id) do
    pid = Agent.get(__MODULE__, &Map.get(&1, session_id))
    if pid, do: send(pid, :close)
    Agent.update(__MODULE__, &Map.delete(&1, session_id))
  end

  def build_response(request) do
    case request["method"] do
      "initialize" ->
        %{
          "jsonrpc" => "2.0",
          "id" => request["id"],
          "result" => %{
            "protocolVersion" => "2024-11-05",
            "serverInfo" => %{"name" => "mock-sse-legacy", "version" => "0.1.0"},
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
            "content" => [%{"type" => "text", "text" => "sse legacy result"}]
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
