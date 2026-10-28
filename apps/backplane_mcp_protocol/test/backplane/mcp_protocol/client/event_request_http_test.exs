defmodule Backplane.McpProtocol.Client.EventRequestHTTPTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Test.HTTPServer

  setup_all do
    {:ok, _} = Application.ensure_all_started(:backplane_mcp_protocol)
    {:ok, _} = Application.ensure_all_started(:gaoxy_http)
    :ok
  end

  test "real modern HTTP retires exact Events pages, pinned history and both MRTR terminals" do
    {name, supervisor} = start_fixture()

    {:ok, retained} =
      Client.start_list_events(name,
        cursor: "opaque/+page",
        meta: %{"fixture/request" => %{"unicode" => "汉字\r\n", "raw" => [nil, false]}},
        track_retirement: true,
        timeout: 10_000
      )

    {:ok, original_identity} = Client.event_request_identity(retained)
    assert {:ok, response} = Client.await_event_request(retained, 2_000)
    assert response.result === page()
    assert_receive {:event_http_wire, %{"method" => "events/list", "params" => params}, headers}
    assert params["cursor"] == "opaque/+page"
    assert params["_meta"]["fixture/request"] == %{"unicode" => "汉字\r\n", "raw" => [nil, false]}
    assert headers["mcp-method"] == "events/list"

    # A tracked page remains pinned beyond the opportunistic 128-job history.
    for _ <- 1..140 do
      {:ok, unrelated} = Client.start_list_events(name)
      assert {:ok, _} = Client.await_event_request(unrelated, 2_000)
    end

    assert {:ok, receipt} = Client.retire_event_request(retained)
    assert receipt.schema == :event_retirement
    assert receipt.local_cleanup == :confirmed
    assert receipt.request_ids == [retained.logical_id]
    assert receipt.terminal == :completed
    assert Map.take(receipt, Map.keys(original_identity)) == original_identity
    refute_receive {:event_http_wire, %{"method" => "notifications/cancelled"}, _}, 20

    {:ok, mrtr} = Client.start_list_events(name, cursor: "mrtr", track_retirement: true)
    assert {:ok, response} = Client.await_event_request(mrtr, 2_000)
    assert response.result === page()
    assert_receive {:event_http_mrtr, "mrtr", first}
    assert_receive {:event_http_mrtr, "mrtr", second}
    refute first == second

    assert {:ok,
            %{terminal: :completed, local_cleanup: :confirmed, request_ids: [^first, ^second]}} =
             Client.retire_event_request(mrtr)

    control = Client.event_cancellation_control()

    {:ok, cancelled} =
      Client.start_list_events(name, cursor: "mrtr-cancel", track_retirement: true)

    assert_receive {:event_http_mrtr, "mrtr-cancel", first_cancel}, 2_000
    assert_receive {:event_http_mrtr, "mrtr-cancel", second_cancel}, 2_000
    assert_receive {:event_http_blocked, ^second_cancel}, 2_000
    :ok = Client.cancel_event_wait(control, "stop", timeout: 2_000)

    assert {:cancelled, %{local_cleanup: :confirmed, request_id: ^second_cancel}} =
             Client.await_event_request(cancelled, 2_000, cancellation: control)

    assert {:ok,
            %{
              schema: :event_retirement,
              terminal: :cancelled,
              local_cleanup: :confirmed,
              request_ids: [^first_cancel, ^second_cancel],
              remote: :unknown
            }} =
             Client.retire_event_request(cancelled)

    {:ok, next} = Client.start_list_events(name)
    assert {:ok, _} = Client.await_event_request(next, 2_000)
    assert {:ok, %{outcome: :confirmed}} = Client.close_connection(supervisor, timeout: 2_000)
  end

  test "expired completed Events retain ledger, HTTP pins and combined capacity" do
    {name, supervisor} = start_fixture()
    {:ok, expired} = Client.start_list_events(name, track_retirement: true, timeout: 200)
    assert {:ok, _} = Client.await_event_request(expired, 1_000)
    client = expired.client
    transport = :sys.get_state(client).transport.name
    assert MapSet.member?(:sys.get_state(transport).request_pins, expired.logical_id)
    await_expiry_settled(client, expired.logical_id)

    assert %{available: false, cleanup: nil, terminal: :completed} =
             :sys.get_state(client).resource_retirements[expired.logical_id]

    assert MapSet.member?(:sys.get_state(transport).request_pins, expired.logical_id)

    assert {:error, %{reason: :event_retirement_unavailable}} =
             Client.retire_event_request(expired, timeout: 5_000)

    for _ <- 1..255 do
      {:ok, retained} = Client.start_list_events(name, track_retirement: true, timeout: 20_000)
      assert {:ok, _} = Client.await_event_request(retained, 2_000)
    end

    assert map_size(:sys.get_state(client).resource_retirements) == 256

    assert {:error, %{reason: :event_retirement_capacity}} =
             Client.start_list_events(name, track_retirement: true)

    assert MapSet.member?(:sys.get_state(transport).request_pins, expired.logical_id)
    assert {:ok, %{outcome: :confirmed}} = Client.close_connection(supervisor, timeout: 2_000)
  end

  defp await_expiry_settled(client, id, attempts \\ 200)
  defp await_expiry_settled(_client, _id, 0), do: flunk("Events expiry did not settle")

  defp await_expiry_settled(client, id, attempts) do
    case :sys.get_state(client).resource_retirements[id] do
      nil ->
        :ok

      %{available: false, cleanup: nil} ->
        :ok

      _ ->
        Process.sleep(5)
        await_expiry_settled(client, id, attempts - 1)
    end
  end

  defp start_fixture do
    server = HTTPServer.open()
    observer = self()
    state = start_supervised!({Agent, fn -> %{} end})
    HTTPServer.stub(server, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    HTTPServer.stub(server, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    HTTPServer.stub(server, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = JSON.decode!(body)
      send(observer, {:event_http_wire, wire, Map.new(conn.req_headers)})

      case fixture(wire, state, observer) do
        nil ->
          Plug.Conn.resp(conn, 202, "")

        response ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(200, JSON.encode!(response))
      end
    end)

    name = String.to_atom("EventsHTTP#{System.unique_integer([:positive])}")

    supervisor =
      start_supervised!(
        {Client,
         name: name,
         transport: {:streamable_http, url: "http://127.0.0.1:#{server.port}/mcp"},
         one_shot: true,
         activation_id: "events-http",
         client_info: %{"name" => to_string(name), "version" => "1"},
         protocol_version: "2026-07-28",
         timeout: 5_000}
      )

    assert :ok = Client.await_ready(name, timeout: 3_000)

    {name, supervisor}
  end

  defp fixture(%{"method" => "server/discover", "id" => id}, _state, _observer) do
    result = %{
      "resultType" => "complete",
      "supportedVersions" => ["2026-07-28"],
      "capabilities" => %{"events" => %{}},
      "ttlMs" => 0,
      "cacheScope" => "private"
    }

    response(id, result)
  end

  defp fixture(%{"method" => "events/list", "id" => id, "params" => params}, state, observer) do
    cursor = params["cursor"]

    result =
      if cursor in ["mrtr", "mrtr-cancel"] do
        send(observer, {:event_http_mrtr, cursor, id})

        if params["requestState"] == "continue" do
          if cursor == "mrtr-cancel" do
            worker = self()
            Agent.update(state, &Map.put(&1, id, worker))
            send(observer, {:event_http_blocked, id})

            receive do
              :release -> :ok
            after
              5_000 -> raise "Events HTTP fixture was not cancelled"
            end
          end

          page()
        else
          %{"resultType" => "input_required", "requestState" => "continue"}
        end
      else
        page()
      end

    response(id, result)
  end

  defp fixture(%{"method" => "notifications/cancelled", "params" => params}, state, _observer) do
    case Agent.get(state, &Map.get(&1, params["requestId"])) do
      pid when is_pid(pid) -> send(pid, :release)
      _ -> :ok
    end

    nil
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp page,
    do: %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "second",
          "delivery" => ["webhook"],
          "inputSchema" => true,
          "payloadSchema" => false
        },
        %{"name" => "first", "inputSchema" => %{"type" => "object"}, "payloadSchema" => true}
      ],
      "nextCursor" => "opaque/+next",
      "_meta" => %{"unchanged" => [1, false, nil]}
    }
end
