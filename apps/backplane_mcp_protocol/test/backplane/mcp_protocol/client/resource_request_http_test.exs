defmodule Backplane.McpProtocol.Client.ResourceRequestHTTPTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Test.HTTPServer

  setup_all do
    {:ok, _} = Application.ensure_all_started(:backplane_mcp_protocol)
    {:ok, _} = Application.ensure_all_started(:gaoxy_http)
    :ok
  end

  for mode <- [:modern_http, :legacy_http, :legacy_sse] do
    @tag transport_mode: mode
    test "#{mode} preserves resource pagination, contents and a shared connection", %{
      transport_mode: mode
    } do
      server = HTTPServer.open()
      test = self()
      state = start_supervised!({Agent, fn -> %{stream: nil, blocked: %{}} end})
      url = "http://127.0.0.1:#{server.port}"
      install_fixture(server, state, mode, test)

      transport =
        if mode == :legacy_sse,
          do: {:sse, server: %{base_url: url, sse_path: "/sse"}},
          else: {:streamable_http, url: url <> "/mcp"}

      name = String.to_atom("ResourceHTTP#{System.unique_integer([:positive])}")

      version =
        case mode do
          :modern_http -> "2026-07-28"
          :legacy_http -> "2025-11-25"
          :legacy_sse -> "2024-11-05"
        end

      supervisor =
        start_supervised!(
          {Client,
           name: name,
           transport: transport,
           one_shot: true,
           activation_id: "resource-http-#{mode}",
           client_info: %{"name" => to_string(name), "version" => "1"},
           capabilities: %{},
           protocol_version: version,
           timeout: 3_000}
        )

      assert :ok = Client.await_ready(name, timeout: 3_000)

      for {start, method, key} <- [
            {&Client.start_list_resources/2, "resources/list", "resources"},
            {&Client.start_list_resource_templates/2, "resources/templates/list",
             "resourceTemplates"}
          ] do
        assert {:ok, handle} =
                 start.(name,
                   cursor: "second",
                   meta: %{"fixture" => "metadata"},
                   progress: [token: "resource-progress", callback: fn _, _, _ -> :ok end]
                 )

        assert {:ok, response} = Client.await_resource_request(handle, 2_000)
        assert response.result[key] == []
        assert response.result["nextCursor"] == "third"
        assert_receive {:resource_http, ^method, %{"cursor" => "second", "_meta" => meta}, _}
        assert meta["progressToken"] == "resource-progress"
        if mode == :modern_http, do: assert(meta["fixture"] == "metadata")
      end

      assert {:ok, handle} = Client.start_read_resource(name, "fixture://contents")
      assert {:ok, response} = Client.await_resource_request(handle, 2_000)
      assert response.result["contents"] == contents()
      assert_receive {:resource_http, "resources/read", %{"uri" => "fixture://contents"}, headers}

      if mode == :modern_http do
        assert headers["mcp-method"] == "resources/read"
        assert headers["mcp-name"] == "fixture://contents"
      end

      owner =
        spawn(fn ->
          {:ok, request} = Client.start_read_resource(name, "fixture://blocked")
          send(test, {:resource_owner_ready, self()})

          receive do
            :cancel -> send(test, {:resource_cancelled, Client.cancel_resource_request(request)})
          end

          send(test, {:resource_cancel_result, Client.await_resource_request(request, 1_000)})
        end)

      assert_receive {:resource_owner_ready, ^owner}, 1_000
      assert_receive {:resource_blocked, _}, 2_000
      assert {:ok, other} = Client.start_read_resource(name, "fixture://contents")
      assert {:ok, other_response} = Client.await_resource_request(other, 2_000)
      assert other_response.result["contents"] == contents()
      send(owner, :cancel)
      assert_receive {:resource_cancelled, {:ok, %{local: :cancelled, remote: :unknown}}}, 2_000
      assert_receive {:resource_cancel_result, {:error, %{reason: :request_cancelled}}}, 2_000

      assert {:ok, next} = Client.start_list_resources(name)
      assert {:ok, _} = Client.await_resource_request(next, 2_000)

      assert {:ok, %{outcome: :confirmed, activation_id: activation}} =
               Client.close_connection(supervisor, timeout: 2_000)

      assert activation == "resource-http-#{mode}"
    end
  end

  defp install_fixture(server, state, mode, test) do
    if mode == :legacy_sse do
      HTTPServer.stub(server, "GET", "/sse", fn conn ->
        stream = self()
        Agent.update(state, &%{&1 | stream: stream})

        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} = Plug.Conn.chunk(conn, "event: endpoint\ndata: /messages\n\n")
        stream_loop(conn)
      end)
    else
      HTTPServer.stub(server, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    end

    path = if mode == :legacy_sse, do: "/messages", else: "/mcp"
    HTTPServer.stub(server, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    HTTPServer.stub(server, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = JSON.decode!(body)
      send(test, {:resource_http, wire["method"], wire["params"], Map.new(conn.req_headers)})
      response = fixture_response(wire, state, mode, test)

      if mode == :legacy_sse do
        if response, do: send(Agent.get(state, & &1.stream), {:response, response})
        Plug.Conn.resp(conn, 202, "")
      else
        if response do
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(200, JSON.encode!(response))
        else
          Plug.Conn.resp(conn, 202, "")
        end
      end
    end)
  end

  defp fixture_response(
         %{"method" => "notifications/cancelled", "params" => params},
         state,
         _mode,
         _test
       ) do
    case Agent.get(state, & &1.blocked[params["requestId"]]) do
      pid when is_pid(pid) -> send(pid, :release)
      _ -> :ok
    end

    nil
  end

  defp fixture_response(%{"id" => id, "method" => method} = wire, state, mode, test) do
    result =
      case method do
        "server/discover" ->
          %{
            "resultType" => "complete",
            "supportedVersions" => ["2026-07-28"],
            "capabilities" => %{"resources" => %{}},
            "ttlMs" => 0,
            "cacheScope" => "private"
          }

        "initialize" ->
          %{
            "protocolVersion" => if(mode == :legacy_sse, do: "2024-11-05", else: "2025-11-25"),
            "capabilities" => %{"resources" => %{}},
            "serverInfo" => %{"name" => "fixture", "version" => "1"}
          }

        "resources/list" ->
          %{"resources" => [], "nextCursor" => "third"}

        "resources/templates/list" ->
          %{"resourceTemplates" => [], "nextCursor" => "third"}

        "resources/read" ->
          if wire["params"]["uri"] == "fixture://blocked" do
            worker = self()
            Agent.update(state, &put_in(&1.blocked[id], worker))
            send(test, {:resource_blocked, id})

            receive do
              :release -> :ok
            after
              3_000 -> raise "resource fixture was not cancelled"
            end
          end

          %{"contents" => contents()}
      end

    result =
      if mode == :modern_http, do: Map.put_new(result, "resultType", "complete"), else: result

    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp fixture_response(_wire, _state, _mode, _test), do: nil

  defp stream_loop(conn) do
    receive do
      {:response, response} ->
        case Plug.Conn.chunk(conn, "event: message\ndata: #{JSON.encode!(response)}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _} -> conn
        end
    end
  end

  defp contents,
    do: [
      %{"uri" => "fixture://contents", "mimeType" => "text/plain", "text" => "汉字\r\n"},
      %{"uri" => "fixture://blob", "mimeType" => "application/octet-stream", "blob" => "AAEC"}
    ]
end
