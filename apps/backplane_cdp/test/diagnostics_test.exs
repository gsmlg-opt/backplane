defmodule Backplane.CDP.MCP.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Backplane.CDP.MCP.{Diagnostics, Observer}

  defmodule ChromeSocket do
    def init({owner, browser}) do
      send(owner, {:observer_socket, self()})
      {:ok, browser}
    end

    def handle_in({bytes, _metadata}, browser) do
      %{"id" => id, "method" => method, "params" => params} = Formata.JSON.decode!(bytes)
      Agent.update(browser, &[{method, params} | &1])
      response = %{"id" => id, "result" => %{}}

      events =
        if method == "Page.handleJavaScriptDialog",
          do: [%{"method" => "Page.javascriptDialogClosed", "params" => %{}}],
          else: []

      {:push, Enum.map(events ++ [response], &{:text, Formata.JSON.encode!(&1)}), browser}
    end

    def handle_info({:emit, events}, browser),
      do: {:push, Enum.map(events, &{:text, Formata.JSON.encode!(&1)}), browser}
  end

  defmodule ChromePlug do
    def init(state), do: state

    def call(conn, state) do
      case conn.request_path do
        "/json/list" ->
          body = [
            %{
              "id" => "page-1",
              "type" => "page",
              "title" => "Test",
              "url" => "about:blank",
              "webSocketDebuggerUrl" => "ws://127.0.0.1:#{conn.port}/devtools/page/page-1"
            }
          ]

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Formata.JSON.encode!(body))

        "/devtools/page/page-1" ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {ChromeSocket, state, []})
      end
    end
  end

  setup do
    browser = start_supervised!({Agent, fn -> [] end})

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {ChromePlug, {self(), browser}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)

    state = %{
      port: port,
      pages: %{},
      selected: nil,
      next_id: 1,
      contexts: %{},
      snapshots: %{},
      observers: %{}
    }

    %{port: port, browser: browser, state: state}
  end

  test "retains bounded console data and filters navigation generations", %{state: state} do
    assert {:ok, observer, state} = Diagnostics.ensure("page-1", state)
    assert_receive {:observer_socket, socket}
    on_exit(fn -> Observer.stop(observer) end)

    emit(socket, observer, [console("old")])

    assert {:ok, [%{"text" => old}], state} =
             Diagnostics.call("list_console_messages", %{}, state)

    assert old =~ "msgid=1 [log] old (1 args)"

    emit(socket, observer, [
      %{
        "method" => "Page.frameNavigated",
        "params" => %{"frame" => %{"id" => "main", "loaderId" => "new-loader"}}
      },
      console("new", "error")
    ])

    assert {:ok, [%{"text" => current}], state} =
             Diagnostics.call("list_console_messages", %{}, state)

    assert current =~ "new"
    refute current =~ "old"

    assert {:ok, [%{"text" => previous}], state} =
             Diagnostics.call(
               "list_console_messages",
               %{"includePreservedMessages" => true},
               state
             )

    assert previous =~ "old"

    assert {:ok, [%{"text" => detail}], state} =
             Diagnostics.call("get_console_message", %{"msgid" => 2}, state)

    assert detail =~ "ID: 2\nMessage: error> new\n### Arguments\nArg #0: new"

    for group <- 1..6 do
      emit(socket, observer, Enum.map(1..90, &console("#{group}-#{&1}")))
    end

    assert {:ok, %{console: retained}} = Observer.data(observer)
    assert length(retained) == 500

    assert {:ok, [%{"text" => page}], _state} =
             Diagnostics.call("list_console_messages", %{"pageSize" => 2, "pageIdx" => 1}, state)

    assert page =~ "Showing 3-4 of 500 (Page 2 of 250)."
  end

  test "network events retain summaries and discard headers, bodies and cookies", %{state: state} do
    assert {:ok, observer, state} = Diagnostics.ensure("page-1", state)
    assert_receive {:observer_socket, socket}
    on_exit(fn -> Observer.stop(observer) end)

    emit(socket, observer, [
      %{
        "method" => "Network.requestWillBeSent",
        "params" => %{
          "requestId" => "r1",
          "type" => "Fetch",
          "request" => %{
            "method" => "POST",
            "url" => "https://example.test/path",
            "headers" => %{"Cookie" => "secret"},
            "postData" => "secret body"
          }
        }
      },
      %{
        "method" => "Network.responseReceived",
        "params" => %{
          "requestId" => "r1",
          "response" => %{"status" => 200, "headers" => %{"Set-Cookie" => "secret"}}
        }
      }
    ])

    assert {:ok, %{network: [request]}} = Observer.data(observer)

    assert Map.keys(request) |> Enum.sort() ==
             Enum.sort([:id, :cdp_id, :url, :method, :resource_type, :status, :generation])

    refute inspect(request) =~ "secret"

    assert {:ok, [%{"text" => text}], _state} =
             Diagnostics.call("list_network_requests", %{"resourceTypes" => ["fetch"]}, state)

    assert text =~ "reqid=1 POST https://example.test/path [200]"

    assert {:ok, [%{"text" => detail}], state} =
             Diagnostics.call("get_network_request", %{"reqid" => 1}, state)

    assert detail ==
             "## Request https://example.test/path\nStatus: 200\nMethod: POST\nResource type: fetch"

    refute detail =~ "secret"

    assert {:ok, [%{"text" => "Nothing is currently selected in the DevTools Network panel."}],
            state} = Diagnostics.call("get_network_request", %{}, state)

    assert {:error, _message, _state} =
             Diagnostics.call(
               "get_network_request",
               %{"reqid" => 1, "responseFilePath" => "/tmp/forbidden-body"},
               state
             )

    assert {:error, "Can't provide details for the reqid 99", _state} =
             Diagnostics.call("get_network_request", %{"reqid" => 99}, state)
  end

  test "handles dialogs and beforeunload on the observer connection", %{
    state: state,
    browser: browser
  } do
    assert {:ok, observer, state} = Diagnostics.ensure("page-1", state)
    assert_receive {:observer_socket, socket}
    on_exit(fn -> Observer.stop(observer) end)

    emit(socket, observer, [dialog("prompt")])

    assert {:ok, [%{"text" => "Successfully accepted the dialog"}], state} =
             Diagnostics.call(
               "handle_dialog",
               %{"action" => "accept", "promptText" => "answer"},
               state
             )

    assert {"Page.handleJavaScriptDialog", %{"accept" => true, "promptText" => "answer"}} in Agent.get(
             browser,
             & &1
           )

    assert {:error, "No open dialog found", _state} =
             Diagnostics.call("handle_dialog", %{"action" => "dismiss"}, state)

    assert :ok = Observer.before_unload(observer, "dismiss")
    emit(socket, observer, [dialog("beforeunload")])
    assert {"Page.handleJavaScriptDialog", %{"accept" => false}} in Agent.get(browser, & &1)
  end

  test "script dialog handling applies only during evaluation", %{state: state, browser: browser} do
    {:ok, observer, _} = Diagnostics.ensure("page-1", state)
    assert_receive {:observer_socket, socket}
    on_exit(fn -> Observer.stop(observer) end)
    :ok = Observer.script_dialog(observer, "typed answer")
    emit(socket, observer, [dialog("prompt")])

    assert {"Page.handleJavaScriptDialog", %{"accept" => true, "promptText" => "typed answer"}} in Agent.get(
             browser,
             & &1
           )

    :ok = Observer.script_dialog(observer, nil)
    emit(socket, observer, [dialog("alert")])
    assert {:error, message} = Observer.script_dialog(observer, "dismiss")
    assert message =~ "handle_dialog"
  end

  test "emulation settings replace prior overrides while omitted extra headers persist", %{
    state: state,
    browser: browser
  } do
    assert {:ok, observer, state} = Diagnostics.ensure("page-1", state)
    assert_receive {:observer_socket, _socket}
    on_exit(fn -> Observer.stop(observer) end)

    assert {:ok, [%{"text" => "Emulation configured successfully"}], state} =
             Diagnostics.call(
               "emulate",
               %{
                 "viewport" => "390x844x3,mobile,touch",
                 "colorScheme" => "dark",
                 "geolocation" => "37.7,-122.4",
                 "networkConditions" => "Fast 4G"
               },
               state
             )

    requests = Agent.get(browser, & &1)

    assert {"Network.emulateNetworkConditions",
            %{
              "offline" => false,
              "latency" => 165,
              "downloadThroughput" => 1_012_500,
              "uploadThroughput" => 168_750
            }} in requests

    assert Enum.any?(requests, fn {method, params} ->
             method == "Emulation.setDeviceMetricsOverride" and params["width"] == 390 and
               params["mobile"]
           end)

    refute Enum.any?(requests, fn {method, _params} -> method == "Network.setExtraHTTPHeaders" end)

    assert {:ok, _blocks, _state} = Diagnostics.call("emulate", %{}, state)
    assert {"Emulation.clearDeviceMetricsOverride", %{}} in Agent.get(browser, & &1)
  end

  test "observations remain scoped to their MCP owner and stop after normal owner exit", %{
    port: port
  } do
    owner =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    assert {:ok, first} = Observer.start(port, "page-1", owner)
    assert_receive {:observer_socket, first_socket}
    assert {:ok, second} = Observer.start(port, "page-1")
    assert_receive {:observer_socket, _second_socket}
    on_exit(fn -> Observer.stop(second) end)

    emit(first_socket, first, [console("private")])
    assert {:ok, %{console: []}} = Observer.data(second)
    monitor = Process.monitor(first)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^first, :normal}, 2_000
  end

  test "trace completion is cached until consumed and pruning closes removed targets", %{
    state: state
  } do
    assert {:ok, observer, state} = Diagnostics.ensure("page-1", state)
    assert_receive {:observer_socket, socket}
    on_exit(fn -> Observer.stop(observer) end)

    emit(socket, observer, [
      %{
        "method" => "Tracing.tracingComplete",
        "params" => %{"stream" => "trace-1", "dataLossOccurred" => false}
      }
    ])

    assert {:ok, %{"stream" => "trace-1"}} =
             Observer.wait_event(observer, "Tracing.tracingComplete", 100)

    assert {:error, "Chrome event timed out"} =
             Observer.wait_event(observer, "Tracing.tracingComplete", 20)

    assert %{observers: %{}} = Diagnostics.prune(%{state | pages: %{}})
    refute Process.alive?(observer)
  end

  defp console(text, type \\ "log"),
    do: %{
      "method" => "Runtime.consoleAPICalled",
      "params" => %{"type" => type, "args" => [%{"type" => "string", "value" => text}]}
    }

  defp dialog(type),
    do: %{
      "method" => "Page.javascriptDialogOpening",
      "params" => %{"type" => type, "message" => "Question?"}
    }

  defp emit(socket, observer, events) do
    send(socket, {:emit, events})
    assert {:ok, %{}} = Observer.command(observer, "Runtime.runIfWaitingForDebugger", %{})
    assert {:ok, %{}} = Observer.command(observer, "Runtime.runIfWaitingForDebugger", %{})
  end
end
