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
                   meta: %{"fixture/request" => %{"label" => "汉字\r\n", "nested" => [1, true]}},
                   progress: [token: "resource-progress", callback: fn _, _, _ -> :ok end]
                 )

        assert {:ok, response} = Client.await_resource_request(handle, 2_000)
        assert response.result[key] == []
        assert response.result["nextCursor"] == "third"
        assert_receive {:resource_http, ^method, %{"cursor" => "second", "_meta" => meta}, _}
        assert meta["progressToken"] == "resource-progress"
        assert meta["fixture/request"] == %{"label" => "汉字\r\n", "nested" => [1, true]}
      end

      assert {:ok, handle} =
               Client.start_read_resource(name, "fixture://contents",
                 meta: %{"fixture/read" => ["汉字", 1]}
               )

      assert {:ok, response} = Client.await_resource_request(handle, 2_000)
      assert response.result["contents"] == contents()

      assert_receive {:resource_http, "resources/read",
                      %{"uri" => "fixture://contents", "_meta" => read_meta}, headers}

      assert read_meta["fixture/read"] == ["汉字", 1]

      if mode == :modern_http do
        assert headers["mcp-method"] == "resources/read"
        assert headers["mcp-name"] == "fixture://contents"

        assert {:ok, events} =
                 Client.start_list_events(name,
                   cursor: "opaque/+events",
                   meta: %{"fixture/event" => true}
                 )

        assert {:ok, page} = Client.await_event_request(events, 2_000)
        assert page.result == event_page()

        assert_receive {:resource_http, "events/list",
                        %{"cursor" => "opaque/+events", "_meta" => event_meta}, event_headers}

        assert event_meta["fixture/event"] == true
        assert event_meta["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
        assert event_headers["mcp-method"] == "events/list"
      end

      owner =
        spawn(fn ->
          {:ok, request} = Client.start_read_resource(name, "fixture://blocked")
          send(test, {:resource_owner_ready, self()})

          receive do
            :cancel ->
              send(
                test,
                {:resource_cancelled,
                 Client.cancel_resource_request(request, "client_cancelled", verified: true)}
              )
          end

          send(test, {:resource_cancel_result, Client.await_resource_request(request, 1_000)})
        end)

      assert_receive {:resource_owner_ready, ^owner}, 1_000
      assert_receive {:resource_blocked, first_id, "fixture://blocked"}, 2_000
      assert {:ok, other} = Client.start_read_resource(name, "fixture://blocked-other")
      assert_receive {:resource_blocked, other_id, "fixture://blocked-other"}, 2_000
      refute other_id == first_id
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 1)
      send(owner, :cancel)
      assert_receive {:resource_cancelled, {:ok, report}}, 2_000
      assert report.local == :cancelled
      assert report.local_cleanup == :confirmed
      assert report.request_id == first_id
      assert report.remote == :unknown
      assert report.cleanup_evidence.workers_down
      assert report.cleanup_evidence.transport == :confirmed
      assert_receive {:resource_cancel_result, {:error, %{reason: :request_cancelled}}}, 2_000
      assert {:error, %{reason: :request_timeout}} = Client.await_resource_request(other, 1)
      other_worker = Agent.get(state, & &1.blocked[other_id])
      assert Process.alive?(other_worker)
      send(other_worker, :release)
      assert {:ok, other_response} = Client.await_resource_request(other, 2_000)
      assert other_response.result["contents"] == contents()

      assert {:ok, next} = Client.start_list_resources(name)
      assert {:ok, _} = Client.await_resource_request(next, 2_000)

      assert {:ok, %{outcome: :confirmed, activation_id: activation}} =
               Client.close_connection(supervisor, timeout: 2_000)

      assert activation == "resource-http-#{mode}"
    end
  end

  test "queued HTTP sends cannot allocate a request after their original deadline" do
    server = HTTPServer.open()
    test = self()

    HTTPServer.stub(server, "POST", "/mcp", fn conn ->
      send(test, :expired_http_dispatched)
      Plug.Conn.resp(conn, 202, "")
    end)

    {:ok, transport} =
      Backplane.McpProtocol.Transport.StreamableHTTP.start_link(
        name: nil,
        client: self(),
        url: "http://127.0.0.1:#{server.port}/mcp"
      )

    :ok = :sys.suspend(transport)

    sender =
      spawn(fn ->
        result =
          try do
            Backplane.McpProtocol.Transport.StreamableHTTP.send_message(transport, "{}",
              timeout: 10
            )
          catch
            :exit, {:timeout, _} -> :send_timed_out
          end

        send(test, {:expired_sender, result})
      end)

    assert_receive {:expired_sender, :send_timed_out}, 1_000
    refute Process.alive?(sender)
    :ok = :sys.resume(transport)
    refute_receive :expired_http_dispatched, 100

    assert {:ok, %{outcome: :confirmed}} =
             Backplane.McpProtocol.Transport.StreamableHTTP.close(transport, timeout: 1_000)

    GenServer.stop(transport)
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
            "capabilities" => %{"resources" => %{}, "events" => %{}},
            "ttlMs" => 0,
            "cacheScope" => "private"
          }

        "initialize" ->
          %{
            "protocolVersion" => if(mode == :legacy_sse, do: "2024-11-05", else: "2025-11-25"),
            "capabilities" => %{"resources" => %{}},
            "serverInfo" => %{"name" => "fixture", "version" => "1"}
          }

        "events/list" ->
          event_page()

        "resources/list" ->
          %{"resources" => [], "nextCursor" => "third"}

        "resources/templates/list" ->
          %{"resourceTemplates" => [], "nextCursor" => "third"}

        "resources/read" ->
          if wire["params"]["uri"] in ["fixture://blocked", "fixture://blocked-other"] do
            worker = self()
            Agent.update(state, &put_in(&1.blocked[id], worker))
            send(test, {:resource_blocked, id, wire["params"]["uri"]})

            receive do
              :release -> :ok
            after
              5_000 -> raise "resource fixture was not cancelled"
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

  defp event_page,
    do: %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "comment.created",
          "description" => "汉字",
          "delivery" => ["webhook"],
          "inputSchema" => %{"type" => "object"},
          "payloadSchema" => true
        },
        %{
          "name" => "comment.updated",
          "delivery" => ["webhook", "other"],
          "inputSchema" => false,
          "payloadSchema" => %{"type" => "object"}
        }
      ],
      "nextCursor" => "opaque/next",
      "extension" => [1, 2]
    }

  defp contents,
    do: [
      %{"uri" => "fixture://contents", "mimeType" => "text/plain", "text" => "汉字\r\n"},
      %{"uri" => "fixture://blob", "mimeType" => "application/octet-stream", "blob" => "AAEC"}
    ]
end
