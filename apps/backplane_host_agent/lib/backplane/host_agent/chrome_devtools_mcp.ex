defmodule Backplane.HostAgent.ChromeDevToolsMCP do
  @moduledoc "Streamable HTTP adapter for clients expecting the Chrome DevTools tool names."

  import Plug.Conn
  alias Backplane.CDP
  alias Backplane.CDP.MCP

  def call(conn) do
    cond do
      not CDP.enabled?() -> send_resp(conn, 404, "")
      not allowed_origin?(conn) -> send_resp(conn, 403, "")
      true -> handle(conn)
    end
  end

  def allowed_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        true

      [origin] ->
        Enum.any?(["127.0.0.1", "localhost", "[::1]"], fn host ->
          base = URI.new!("#{conn.scheme}://#{host}")
          origin == URI.to_string(%{base | port: conn.port})
        end)

      _ ->
        false
    end
  end

  defp handle(
         %{
           method: "POST",
           body_params: %{"jsonrpc" => "2.0", "method" => "initialize", "id" => id} = body
         } = conn
       ) do
    version =
      case body do
        %{"params" => %{"protocolVersion" => version}} -> version
        _ -> nil
      end

    version =
      if version in ~w(2024-11-05 2025-03-26 2025-06-18 2025-11-25),
        do: version,
        else: "2025-11-25"

    case MCP.open() do
      {:ok, token} ->
        conn
        |> put_resp_header("mcp-session-id", token)
        |> result(id, %{
          "protocolVersion" => version,
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "backplane_cdp", "version" => Backplane.HostAgent.version()}
        })

      {:error, _} ->
        error(conn, id, 503, -32_000, "Cannot start a Chrome DevTools session")
    end
  end

  defp handle(%{method: method} = conn) when method in ["POST", "DELETE"] do
    case get_req_header(conn, "mcp-session-id") do
      [token] ->
        case MCP.lookup(token) do
          {:ok, pid} when method == "DELETE" ->
            DynamicSupervisor.terminate_child(CDP.Sessions, pid)
            send_resp(conn, 200, "")

          {:ok, pid} ->
            request(conn, conn.body_params, pid)

          _ ->
            error(conn, nil, 404, -32_000, "Unknown session. Initialize again.")
        end

      _ ->
        error(conn, nil, 400, -32_000, "Missing Mcp-Session-Id")
    end
  end

  defp handle(conn), do: conn |> put_resp_header("allow", "POST, DELETE") |> send_resp(405, "")

  defp request(conn, %{"jsonrpc" => "2.0", "method" => method} = body, pid)
       when is_binary(method) do
    case Map.fetch(body, "id") do
      :error -> send_resp(conn, 202, "")
      {:ok, id} -> dispatch(conn, id, method, Map.get(body, "params", %{}), pid)
    end
  end

  defp request(conn, _, _), do: error(conn, nil, 400, -32_600, "Invalid JSON-RPC request")

  defp dispatch(conn, id, "tools/list", _, _), do: result(conn, id, %{"tools" => MCP.tools()})
  defp dispatch(conn, id, "ping", _, _), do: result(conn, id, %{})

  defp dispatch(conn, id, "tools/call", %{"name" => name} = params, pid) when is_binary(name) do
    if MCP.known?(name) do
      case MCP.call(pid, name, Map.get(params, "arguments", %{})) do
        {:ok, blocks} ->
          result(conn, id, %{"content" => blocks})

        {:error, reason} ->
          result(conn, id, %{
            "isError" => true,
            "content" => [%{"type" => "text", "text" => reason}]
          })
      end
    else
      error(conn, id, 200, -32_602, "Unknown tool: #{name}")
    end
  end

  defp dispatch(conn, id, "tools/call", _, _),
    do: error(conn, id, 200, -32_602, "Invalid tool parameters")

  defp dispatch(conn, id, _, _, _), do: error(conn, id, 200, -32_601, "Method not found")

  defp result(conn, id, value), do: reply(conn, 200, %{jsonrpc: "2.0", id: id, result: value})

  defp error(conn, id, status, code, message),
    do: reply(conn, status, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

  defp reply(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Formata.JSON.encode!(body))
end
