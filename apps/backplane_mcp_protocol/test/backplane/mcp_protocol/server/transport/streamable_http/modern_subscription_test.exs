defmodule ModernHTTPSubscriptionTask5Server do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-http-subscription-task-5",
    version: "1.0.0",
    capabilities: [
      {:tools, list_changed?: true},
      {:prompts, list_changed?: false},
      {:resources, list_changed?: true, subscribe?: true}
    ],
    protocol_versions: ["2026-07-28"]

  @impl true
  def handle_request(request, frame) do
    {:reply, %{"requestId" => request["id"]}, frame}
  end
end

defmodule ModernHTTPSubscriptionTask5RaceHub do
  @moduledoc false

  use GenServer

  alias Backplane.McpProtocol.Server.Modern.Subscription
  alias Backplane.McpProtocol.Server.Modern.Subscriptions

  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:subscribe, subscriber, request_context}, from, state) do
    {:ok, subscription} = Subscription.new(subscriber, request_context)

    Process.unregister(state.name)
    {:ok, replacement} = GenServer.start(Subscriptions, :ok, name: state.name)
    send(state.test_pid, {:replacement_hub, replacement})

    send(subscriber, {
      :mcp_subscription,
      subscription.ref,
      Subscription.acknowledged(subscription)
    })

    GenServer.reply(from, {:ok, subscription.ref})
    {:stop, :normal, state}
  end
end

defmodule Backplane.McpProtocol.Server.Transport.StreamableHTTP.ModernSubscriptionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.McpProtocol.Server.Modern.Subscriptions
  alias Backplane.McpProtocol.Server.Registry
  alias Backplane.McpProtocol.Server.Supervisor, as: ServerSupervisor
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, as: StreamableHTTPPlug

  @version "2026-07-28"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  setup do
    task_supervisor = Registry.task_supervisor_name(ModernHTTPSubscriptionTask5Server)
    session_supervisor = Registry.session_supervisor_name(ModernHTTPSubscriptionTask5Server)
    subscriptions = Registry.subscriptions_name(ModernHTTPSubscriptionTask5Server)

    start_supervised!({Task.Supervisor, name: task_supervisor})
    start_supervised!({DynamicSupervisor, name: session_supervisor, strategy: :one_for_one})
    start_supervised!({Subscriptions, name: subscriptions})

    session_config = %{
      server_module: ModernHTTPSubscriptionTask5Server,
      registry_mod: Registry.None,
      transport: [layer: StubTransport, name: nil],
      session_idle_timeout: nil,
      timeout: 1_000,
      task_supervisor: task_supervisor,
      max_concurrency: 1
    }

    :persistent_term.put(
      {ServerSupervisor, ModernHTTPSubscriptionTask5Server, :session_config},
      session_config
    )

    :persistent_term.erase({ServerSupervisor, ModernHTTPSubscriptionTask5Server, :authorization_config})

    on_exit(fn ->
      :persistent_term.erase({ServerSupervisor, ModernHTTPSubscriptionTask5Server, :session_config})

      :persistent_term.erase({ServerSupervisor, ModernHTTPSubscriptionTask5Server, :authorization_config})
    end)

    %{
      opts: StreamableHTTPPlug.init(server: ModernHTTPSubscriptionTask5Server),
      subscriptions: subscriptions
    }
  end

  test "listen owns a request SSE stream, acknowledges first, filters events, and completes gracefully", context do
    request =
      modern_request("subscriptions/listen", "listen-http", %{
        "notifications" => %{
          "toolsListChanged" => true,
          "promptsListChanged" => true,
          "resourceSubscriptions" => ["file:///exact"]
        }
      })

    task = Task.async(fn -> post_modern(context.opts, request) end)
    await_subscription_count(context.subscriptions, 1)

    assert :ok =
             Subscriptions.publish(
               context.subscriptions,
               notification("notifications/prompts/list_changed", %{"ignored" => true})
             )

    assert :ok =
             Subscriptions.publish(
               context.subscriptions,
               notification("notifications/resources/updated", %{"uri" => "file:///exact/child"})
             )

    assert :ok =
             Subscriptions.publish(
               context.subscriptions,
               notification("notifications/tools/list_changed", %{
                 "revision" => 7,
                 "_meta" => %{"trace" => "event"}
               })
             )

    assert :ok = Subscriptions.close(context.subscriptions)
    conn = Task.await(task)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert get_resp_header(conn, "mcp-session-id") == []

    body = response_body(conn)
    refute body =~ "\nid:"
    refute body =~ "\nretry:"

    [ack, event, complete] = decode_sse(body)

    assert %{
             "method" => "notifications/subscriptions/acknowledged",
             "params" => %{
               "notifications" => %{
                 "toolsListChanged" => true,
                 "resourceSubscriptions" => ["file:///exact"]
               },
               "_meta" => %{@subscription_id_key => "listen-http"}
             }
           } = ack

    assert %{
             "method" => "notifications/tools/list_changed",
             "params" => %{
               "revision" => 7,
               "_meta" => %{
                 "trace" => "event",
                 @subscription_id_key => "listen-http"
               }
             }
           } = event

    assert %{
             "id" => "listen-http",
             "result" => %{
               "resultType" => "complete",
               "_meta" => %{
                 @subscription_id_key => "listen-http",
                 @server_info_key => %{
                   "name" => "modern-http-subscription-task-5",
                   "version" => "1.0.0"
                 }
               }
             }
           } = complete
  end

  test "listen forces SSE when JSON is the first Accept preference and ordinary POST stays concurrent", context do
    listen =
      modern_request("subscriptions/listen", "open-listen", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    stream_task =
      Task.async(fn ->
        post_modern(context.opts, listen, [
          {"accept", "Application/JSON; charset=utf-8, TEXT/EVENT-STREAM; q=0.9"}
        ])
      end)

    await_subscription_count(context.subscriptions, 1)

    ordinary = post_modern(context.opts, modern_request("tools/list", "ordinary", %{}))

    assert ordinary.status == 200
    assert get_resp_header(ordinary, "content-type") == ["application/json; charset=utf-8"]
    assert %{"id" => "ordinary", "result" => %{"resultType" => "complete"}} = JSON.decode!(ordinary.resp_body)
    refute Task.yield(stream_task, 0)

    assert :ok = Subscriptions.close(context.subscriptions)
    stream = Task.await(stream_task)

    assert Enum.map(decode_sse(response_body(stream)), &Map.get(&1, "method")) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]
  end

  test "pins the subscribed hub PID and exits when it dies even after an immediate named restart", context do
    assert :ok = stop_supervised(Subscriptions)

    {:ok, original_hub} =
      ModernHTTPSubscriptionTask5RaceHub.start_link(
        name: context.subscriptions,
        test_pid: self()
      )

    listen =
      modern_request("subscriptions/listen", "hub-restart", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    stream_task = Task.async(fn -> post_modern(context.opts, listen) end)

    assert_receive {:replacement_hub, replacement_hub}
    on_exit(fn -> if Process.alive?(replacement_hub), do: GenServer.stop(replacement_hub) end)

    refute original_hub == replacement_hub
    assert Process.whereis(context.subscriptions) == replacement_hub
    assert {:ok, conn} = Task.yield(stream_task, 500)

    assert [%{"method" => "notifications/subscriptions/acknowledged"}] =
             decode_sse(response_body(conn))
  end

  test "request-owner exit removes the subscription without a graceful result", context do
    listen =
      modern_request("subscriptions/listen", "disconnect", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    stream_task = Task.async(fn -> post_modern(context.opts, listen) end)
    await_subscription_count(context.subscriptions, 1)
    _ = Task.shutdown(stream_task, :brutal_kill)
    await_subscription_count(context.subscriptions, 0)
  end

  test "a real client disconnect silently removes the request-owned subscription", context do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      StreamableHTTPPlug.call(conn, context.opts)
    end)

    listen =
      modern_request("subscriptions/listen", "tcp-disconnect", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    body = JSON.encode!(listen)

    request = [
      "POST /mcp HTTP/1.1\r\n",
      "Host: 127.0.0.1\r\n",
      "Content-Type: application/json\r\n",
      "Accept: application/json, text/event-stream\r\n",
      "Mcp-Protocol-Version: #{@version}\r\n",
      "Mcp-Method: subscriptions/listen\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: keep-alive\r\n",
      "\r\n",
      body
    ]

    assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, bypass.port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert :ok = :gen_tcp.send(socket, request)
    await_subscription_count(context.subscriptions, 1)

    response = receive_until(socket, "notifications/subscriptions/acknowledged")
    assert response =~ "HTTP/1.1 200"
    refute response =~ ~s("resultType":"complete")
    assert :ok = Bypass.pass(bypass)

    assert :ok = :gen_tcp.close(socket)

    assert :ok =
             Subscriptions.publish(
               context.subscriptions,
               notification("notifications/tools/list_changed", %{"after" => "disconnect"})
             )

    await_subscription_count(context.subscriptions, 0, 2_000)
  end

  test "invalid filters are finite JSON-RPC errors and never open a stream", context do
    invalid_filters = [
      %{},
      %{"notifications" => []},
      %{"notifications" => %{"toolsListChanged" => "yes"}},
      %{"notifications" => %{"resourceSubscriptions" => [1]}}
    ]

    for params <- invalid_filters do
      conn = post_modern(context.opts, modern_request("subscriptions/listen", "invalid-filter", params))

      assert conn.status == 400
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert %{"id" => "invalid-filter", "error" => %{"code" => -32_602}} = JSON.decode!(conn.resp_body)
      assert map_size(:sys.get_state(context.subscriptions).subscriptions) == 0
    end
  end

  test "listen requires an SSE Accept value and validates routing headers and request metadata before subscribing",
       context do
    valid =
      modern_request("subscriptions/listen", "invalid-wire", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    no_sse = post_modern(context.opts, valid, [{"accept", "application/json"}])
    assert no_sse.status == 406

    mismatch = post_modern(context.opts, valid, [{"mcp-method", "tools/list"}])
    assert mismatch.status == 400
    assert %{"error" => %{"code" => -32_020}} = JSON.decode!(mismatch.resp_body)

    missing_metadata =
      update_in(valid, ["params", "_meta"], fn meta ->
        Map.delete(meta, "io.modelcontextprotocol/clientCapabilities")
      end)

    invalid_metadata = post_modern(context.opts, missing_metadata)
    assert invalid_metadata.status == 400
    assert %{"error" => %{"code" => -32_602}} = JSON.decode!(invalid_metadata.resp_body)

    assert map_size(:sys.get_state(context.subscriptions).subscriptions) == 0
  end

  test "listen requires both JSON and SSE Accept media types", context do
    listen =
      modern_request("subscriptions/listen", "sse-only", %{
        "notifications" => %{"toolsListChanged" => true}
      })

    request_task =
      Task.async(fn ->
        post_modern(context.opts, listen, [{"accept", "text/event-stream"}])
      end)

    assert {:ok, conn} = Task.yield(request_task, 500)
    assert conn.status == 406
    assert map_size(:sys.get_state(context.subscriptions).subscriptions) == 0

    spoofed_media_types = [
      {"application/json-seq, text/event-stream", "json-prefix"},
      {"application/json, x/text/event-stream", "sse-suffix"}
    ]

    for {accept, request_id} <- spoofed_media_types do
      conn =
        post_modern(
          context.opts,
          modern_request("tools/list", request_id, %{}),
          [{"accept", accept}]
        )

      assert conn.status == 406
    end
  end

  test "SSE-only Accept rejects spoofed listen headers on legacy and ordinary modern requests", context do
    legacy_request = %{
      "jsonrpc" => "2.0",
      "id" => "legacy-spoof",
      "method" => "tools/list",
      "params" => %{}
    }

    legacy =
      :post
      |> conn("/", JSON.encode!(legacy_request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-method", "subscriptions/listen")
      |> StreamableHTTPPlug.call(context.opts)

    assert legacy.status == 406

    ordinary_modern =
      post_modern(
        context.opts,
        modern_request("tools/list", "modern-spoof", %{}),
        [{"accept", "text/event-stream"}, {"mcp-method", "subscriptions/listen"}]
      )

    assert ordinary_modern.status == 406
    assert map_size(:sys.get_state(context.subscriptions).subscriptions) == 0
  end

  defp post_modern(opts, request, extra_headers \\ []) do
    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", @version},
      {"mcp-method", request["method"]}
    ]

    conn =
      :post
      |> conn("/", JSON.encode!(request))
      |> assign(:test_pid, self())

    headers
    |> Map.new()
    |> Map.merge(Map.new(extra_headers))
    |> Map.to_list()
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> StreamableHTTPPlug.call(opts)
  end

  defp modern_request(method, id, params) do
    meta = %{
      "trace" => "request",
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp response_body(%Plug.Conn{resp_body: ""} = conn) do
    case conn.adapter do
      {Plug.Adapters.Test.Conn, %{chunks: chunks}} when is_binary(chunks) -> chunks
      _other -> ""
    end
  end

  defp response_body(%Plug.Conn{resp_body: body}) when is_binary(body), do: body

  defp decode_sse(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      refute event =~ "\nid:"
      refute event =~ "\nretry:"
      assert event =~ "event: message"

      event
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map_join("\n", &String.replace_prefix(&1, "data: ", ""))
      |> JSON.decode!()
    end)
  end

  defp receive_until(socket, expected, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_until(socket, expected, "", deadline)
  end

  defp do_receive_until(socket, expected, received, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case :gen_tcp.recv(socket, 0, remaining) do
      {:ok, data} ->
        received = received <> data

        if String.contains?(received, expected) do
          received
        else
          do_receive_until(socket, expected, received, deadline)
        end

      {:error, reason} ->
        flunk("socket closed before receiving #{inspect(expected)}: #{inspect(reason)}; got #{inspect(received)}")
    end
  end

  defp await_subscription_count(hub, expected, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_subscription_count(hub, expected, deadline)
  end

  defp do_await_subscription_count(hub, expected, deadline) do
    state = :sys.get_state(hub)

    cond do
      map_size(state.subscriptions) == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{expected} subscriptions: #{inspect(state)}")

      true ->
        receive do
        after
          1 -> do_await_subscription_count(hub, expected, deadline)
        end
    end
  end
end
