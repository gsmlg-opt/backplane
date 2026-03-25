defmodule Backplane.ConnCase do
  @moduledoc """
  Base case template for HTTP/MCP transport tests.
  Provides helpers for sending JSON-RPC requests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Plug.Test
      import Backplane.ConnCase
    end
  end

  setup tags do
    Backplane.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc "Send a JSON-RPC request to the MCP endpoint."
  def mcp_request(method, params \\ nil, opts \\ []) do
    id = Keyword.get(opts, :id, 1)
    auth_token = Keyword.get(opts, :auth_token)

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => id
    }

    body = if params, do: Map.put(body, "params", params), else: body

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if auth_token do
        Plug.Conn.put_req_header(conn, "authorization", "Bearer #{auth_token}")
      else
        conn
      end

    conn = Backplane.Transport.Router.call(conn, Backplane.Transport.Router.init([]))

    Jason.decode!(conn.resp_body)
  end

  @doc "Send a JSON-RPC request and return the full conn (for header inspection)."
  def mcp_request_conn(method, params \\ nil, opts \\ []) do
    id = Keyword.get(opts, :id, 1)
    auth_token = Keyword.get(opts, :auth_token)

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => id
    }

    body = if params, do: Map.put(body, "params", params), else: body

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if auth_token do
        Plug.Conn.put_req_header(conn, "authorization", "Bearer #{auth_token}")
      else
        conn
      end

    Backplane.Transport.Router.call(conn, Backplane.Transport.Router.init([]))
  end

  @doc "Send a raw POST to /mcp with a custom body."
  def raw_mcp_request(body, opts \\ []) do
    auth_token = Keyword.get(opts, :auth_token)

    conn =
      Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      if auth_token do
        Plug.Conn.put_req_header(conn, "authorization", "Bearer #{auth_token}")
      else
        conn
      end

    conn = Backplane.Transport.Router.call(conn, Backplane.Transport.Router.init([]))

    Jason.decode!(conn.resp_body)
  end
end
