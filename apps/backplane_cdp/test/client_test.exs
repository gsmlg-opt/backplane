defmodule Backplane.CDP.ClientTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP.Client

  defmodule ChromeSocket do
    def init(state), do: {:ok, state}

    def handle_in({bytes, _metadata}, {owner, :disconnect} = state) do
      send(owner, {:cdp_request, Formata.JSON.decode!(bytes)})
      {:stop, :normal, state}
    end

    def handle_in({bytes, _metadata}, {owner, mode} = state) do
      request = Formata.JSON.decode!(bytes)
      send(owner, {:cdp_request, request})

      response =
        case mode do
          :protocol_error ->
            %{
              "id" => request["id"],
              "error" => %{"code" => -32_601, "message" => "Unknown method"}
            }

          _ ->
            %{"id" => request["id"], "result" => %{"value" => 42}}
        end

      messages = [
        %{"method" => "Runtime.executionContextCreated", "params" => %{}},
        %{"id" => 19, "result" => %{"value" => "unrelated"}},
        response
      ]

      {:push, Enum.map(messages, &{:text, Formata.JSON.encode!(&1)}), state}
    end

    def handle_info(_message, state), do: {:ok, state}
  end

  defmodule ChromePlug do
    def init(options), do: options

    def call(conn, {_owner, :oversized}) do
      Plug.Conn.send_resp(conn, 200, String.duplicate(" ", 1_048_577))
    end

    def call(conn, {_owner, :invalid_json}) do
      Plug.Conn.send_resp(conn, 200, "{")
    end

    def call(conn, {owner, mode} = state) do
      send(owner, {:discovery, conn.request_path})
      ws = "ws://127.0.0.1:#{conn.port}"

      case conn.request_path do
        "/json/list" ->
          url =
            case mode do
              :external_url -> "ws://example.org:#{conn.port}/devtools/page/page-1"
              :invalid_url -> "ws://127.0.0.1:invalid/devtools/page/page-1"
              _ -> ws <> "/devtools/page/page-1"
            end

          json(conn, [
            %{
              "id" => "page-1",
              "type" => "page",
              "title" => "Fixture",
              "url" => "about:blank",
              "webSocketDebuggerUrl" => url
            },
            %{
              "id" => "worker-1",
              "type" => "service_worker",
              "title" => "Worker",
              "url" => "about:blank"
            }
          ])

        "/json/version" ->
          json(conn, %{"webSocketDebuggerUrl" => ws <> "/devtools/browser/browser-1"})

        "/devtools/page/page-1" ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {ChromeSocket, state, []})

        "/devtools/browser/browser-1" ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {ChromeSocket, state, []})

        _ ->
          Plug.Conn.send_resp(conn, 404, "missing")
      end
    end

    defp json(conn, value) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Formata.JSON.encode!(value))
    end
  end

  defp chrome(mode \\ :normal) do
    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {ChromePlug, {self(), mode}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    port
  end

  test "lists page targets with stable IDs and excludes service workers" do
    assert {:ok, [%{"id" => "page-1", "title" => "Fixture", "url" => "about:blank"}]} =
             Client.pages(chrome())
  end

  test "correlates page command responses while ignoring events and other IDs" do
    assert {:ok, %{"value" => 42}} =
             Client.command(chrome(), "page-1", "Runtime.evaluate", %{"expression" => "6 * 7"})

    assert_receive {:cdp_request,
                    %{
                      "id" => 1,
                      "method" => "Runtime.evaluate",
                      "params" => %{"expression" => "6 * 7"}
                    }}

    refute_receive {HTTP.WebSocket, _, _}
    refute_receive {HTTP.WebSocket, _, _, _}
  end

  test "discovers the browser endpoint for browser commands" do
    assert {:ok, %{"value" => 42}} =
             Client.command(chrome(), :browser, "Target.createTarget", %{"url" => "about:blank"})

    assert_receive {:discovery, "/json/version"}
    assert_receive {:discovery, "/devtools/browser/browser-1"}
  end

  test "keeps related commands and queued events on one connection" do
    port = chrome()

    assert {:ok, %{"value" => 42}} =
             Client.with_connection(port, "page-1", fn connection ->
               assert {:ok, %{"value" => 42}} =
                        Client.send_command(connection, "DOM.resolveNode", %{"backendNodeId" => 1})

               assert {:ok, %{}} =
                        Client.wait_for_event(connection, "Runtime.executionContextCreated", 0)

               Client.send_command(connection, "Runtime.callFunctionOn", %{
                 "objectId" => "same-session"
               })
             end)

    assert_receive {:cdp_request, %{"id" => 1}}
    assert_receive {:cdp_request, %{"id" => 2}}
    assert_receive {:discovery, "/devtools/page/page-1"}
    refute_receive {:discovery, "/devtools/page/page-1"}
  end

  test "returns CDP errors and sends the command once" do
    assert {:error, "Chrome protocol error: Unknown method"} =
             Client.command(chrome(:protocol_error), "page-1", "Runtime.unknown", %{})

    assert_receive {:cdp_request, _}
    refute_receive {:cdp_request, _}
  end

  test "rejects discovery URLs outside the configured loopback browser" do
    assert {:error, "Chrome returned an invalid local WebSocket URL"} =
             Client.command(chrome(:external_url), "page-1", "Runtime.evaluate", %{})

    refute_receive {:cdp_request, _}
  end

  test "returns errors for malformed discovery JSON" do
    assert {:error, "Invalid JSON in Chrome discovery response"} =
             Client.pages(chrome(:invalid_json))
  end

  test "bounds discovery response memory" do
    assert {:error, "Chrome discovery response is too large"} = Client.pages(chrome(:oversized))
  end

  test "rejects malformed discovered WebSocket URLs" do
    assert {:error, "Chrome returned an invalid local WebSocket URL"} =
             Client.command(chrome(:invalid_url), "page-1", "Runtime.evaluate", %{})
  end

  test "reports disconnection without replaying the command" do
    assert {:error, "Chrome WebSocket closed during command"} =
             Client.command(chrome(:disconnect), "page-1", "Runtime.evaluate", %{})

    assert_receive {:cdp_request, _}
    refute_receive {:cdp_request, _}
  end

  test "rejects unavailable pages and invalid input" do
    assert {:error, "Chrome page was not found"} =
             Client.command(chrome(), "worker-1", "Runtime.evaluate", %{})

    assert {:error, "Invalid Chrome page ID"} =
             Client.command(9222, "../page", "Runtime.evaluate", %{})

    assert {:error, "Invalid CDP method"} = Client.command(9222, :browser, "invalid", %{})
    assert {:error, "Invalid Chrome debugging port"} = Client.pages(0)
  end
end
