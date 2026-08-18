defmodule Backplane.Test.MockMcpPlug do
  @moduledoc """
  Option-driven MCP server fixture for upstream proxy tests.

  Every request can be reported to an owning test process while the selected
  mode models legacy, modern, and automatic-negotiation outcomes.
  """

  import Plug.Conn

  @legacy_version "2025-11-25"
  @modern_version "2026-07-28"
  @session_id "mock-legacy-session"

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    request = JSON.decode!(body)
    mode = Keyword.get(opts, :mode, :legacy)
    headers = conn.req_headers

    report_request(opts, conn, request, headers)
    session_violation? = report_modern_violation(opts, mode, request["method"], headers)
    maybe_delay(opts, request["method"])

    if session_violation? do
      strict_modern_session_error(conn, request)
    else
      respond(conn, request, mode, opts)
    end
  end

  defp respond(conn, %{"method" => "notifications/" <> _notification}, _mode, _opts) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, %{"method" => "server/discover"}, mode, _opts)
       when mode in [:legacy, :auto_legacy, :legacy_ping_error] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "legacy endpoint")
  end

  defp respond(conn, %{"method" => "server/discover"}, :discover_500, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "server error")
  end

  defp respond(conn, %{"method" => "server/discover"}, :discover_malformed, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, "not-json")
  end

  defp respond(conn, %{"method" => "server/discover", "id" => id}, :discover_jsonrpc_error, _opts) do
    json_response(conn, 400, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    })
  end

  defp respond(conn, %{"method" => "server/discover", "id" => id}, _mode, _opts) do
    json_response(conn, 200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "supportedVersions" => [@modern_version],
        "capabilities" => %{"tools" => %{}},
        "ttlMs" => 0,
        "cacheScope" => "private",
        "_meta" => %{
          "io.modelcontextprotocol/serverInfo" => %{
            "name" => "mock-modern",
            "version" => "0.1.0"
          }
        }
      }
    })
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, mode, _opts)
       when mode in [:modern, :input_required] do
    json_response(conn, 400, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "initialize forbidden"}
    })
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _mode, _opts) do
    conn
    |> put_resp_header("mcp-session-id", @session_id)
    |> json_response(200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @legacy_version,
        "serverInfo" => %{"name" => "mock-legacy", "version" => "0.1.0"},
        "capabilities" => %{"tools" => %{"listChanged" => false}}
      }
    })
  end

  defp respond(conn, %{"method" => "tools/list", "id" => id} = request, mode, opts) do
    params = request["params"] || %{}
    result = catalog_result(opts, params["cursor"])

    result =
      if modern_mode?(mode), do: Map.put_new(result, "resultType", "complete"), else: result

    json_response(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id} = request, :input_required, _opts) do
    json_response(conn, 200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "input_required",
        "inputRequests" => %{
          "sample" => %{
            "method" => "sampling/createMessage",
            "params" => %{"messages" => [], "maxTokens" => 1}
          }
        },
        "requestState" => "opaque-input-required",
        "echoArguments" => get_in(request, ["params", "arguments"])
      }
    })
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id} = request, mode, opts) do
    case call_result(opts, request, mode) do
      {:error, code, message} ->
        json_response(conn, 200, %{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => code, "message" => message}
        })

      result ->
        json_response(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    end
  end

  defp respond(conn, %{"method" => "ping", "id" => id}, mode, _opts)
       when mode in [:modern, :input_required] do
    json_response(conn, 400, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "ping forbidden"}
    })
  end

  defp respond(conn, %{"method" => "ping", "id" => id}, :legacy_ping_error, _opts) do
    json_response(conn, 200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_000, "message" => "health failed"}
    })
  end

  defp respond(conn, %{"method" => "ping", "id" => id}, _mode, _opts) do
    json_response(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  defp respond(conn, %{"id" => id}, _mode, _opts) do
    json_response(conn, 200, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    })
  end

  defp catalog_result(opts, cursor) do
    case Keyword.get(opts, :catalog) do
      provider when is_function(provider, 1) -> provider.(cursor)
      provider when is_function(provider, 0) -> %{"tools" => provider.()}
      tools when is_list(tools) -> %{"tools" => tools}
      nil -> %{"tools" => default_tools()}
    end
  end

  defp call_result(opts, request, mode) do
    case Keyword.get(opts, :call_result) do
      provider when is_function(provider, 1) -> provider.(request)
      result when is_map(result) -> result
      {:error, _code, _message} = error -> error
      nil -> default_call_result(request, mode)
    end
  end

  defp default_call_result(request, mode) do
    result = %{
      "content" => [%{"type" => "text", "text" => "mock result"}],
      "echoArguments" => get_in(request, ["params", "arguments"])
    }

    if modern_mode?(mode), do: Map.put(result, "resultType", "complete"), else: result
  end

  defp default_tools do
    [
      %{
        "name" => "echo",
        "description" => "Echo back the input",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"message" => %{"type" => "string"}}
        }
      },
      %{
        "name" => "greet",
        "description" => "Greet someone",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}}
        }
      }
    ]
  end

  defp report_request(opts, conn, request, headers) do
    if owner = Keyword.get(opts, :owner) do
      send(owner, {
        :upstream_request,
        %{
          method: request["method"],
          params: request["params"] || %{},
          path: conn.request_path,
          headers: headers,
          header_map: Map.new(headers)
        }
      })
    end
  end

  defp report_modern_violation(opts, mode, method, headers) do
    owner = Keyword.get(opts, :owner)

    session? =
      Enum.any?(headers, fn {name, _value} ->
        is_binary(name) and String.downcase(name) == "mcp-session-id"
      end)

    if modern_mode?(mode) and owner do
      if method in ["initialize", "ping"] or session? do
        send(owner, {:strict_modern_violation, %{method: method, session?: session?}})
      end
    end

    modern_mode?(mode) and session?
  end

  defp modern_mode?(mode), do: mode in [:modern, :input_required]

  defp maybe_delay(opts, method) do
    case opts |> Keyword.get(:delays, %{}) |> Map.get(method) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _missing_or_invalid -> :ok
    end
  end

  defp strict_modern_session_error(conn, request) do
    json_response(conn, 400, %{
      "jsonrpc" => "2.0",
      "id" => request["id"],
      "error" => %{"code" => -32_600, "message" => "session header forbidden"}
    })
  end

  defp json_response(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end
end
