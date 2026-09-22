defmodule Backplane.McpProtocol.Client.ToolCallTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.Client.ToolCall
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.ToolCallTransport

  test "an immediate response settles the handle and stops a blocked dispatch" do
    gate = make_ref()
    {client, transport} = start_client([{:block, gate}])

    assert {:ok, handle} = Client.start_tool_call(client, "immediate", %{})
    {dispatch, request} = receive_wire("tools/call")
    dispatch_monitor = Process.monitor(dispatch)

    respond(client, request["id"], complete("done"))

    assert {:ok, response} = Client.await_tool_call(handle, 1_000)
    assert response.result["content"] == [%{"text" => "done", "type" => "text"}]
    assert_receive {:DOWN, ^dispatch_monitor, :process, ^dispatch, :killed}, 1_000
    assert clean_client?(client)
    assert Agent.get(transport, & &1.actions) == []
  end

  test "an immediate JSON-RPC error settles the handle and stops a blocked dispatch" do
    gate = make_ref()
    {client, _transport} = start_client([{:block, gate}])

    assert {:ok, handle} = Client.start_tool_call(client, "immediate-error", %{})
    {dispatch, request} = receive_wire("tools/call")
    dispatch_monitor = Process.monitor(dispatch)

    respond_error(client, request["id"], -32_001, "failed")

    assert {:error, %Error{}} = Client.await_tool_call(handle, 1_000)
    assert_receive {:DOWN, ^dispatch_monitor, :process, ^dispatch, :killed}, 1_000
    assert clean_client?(client)
  end

  test "cancelling A leaves B and the shared client usable" do
    {client, _transport} = start_client([:ok, :ok, :ok])

    assert {:ok, handle_a} = Client.start_tool_call(client, "a", %{})
    assert {:ok, handle_b} = Client.start_tool_call(client, "b", %{})
    requests = receive_tool_requests(2, %{})

    assert {:ok,
            %{
              local: :cancelled,
              notification_delivery: :accepted,
              remote: :unknown
            }} = Client.cancel_tool_call(handle_a, "stop a")

    {_pid, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == requests["a"]["id"]
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle_a, 1_000)

    respond(client, requests["b"]["id"], complete("b done"))
    assert {:ok, response} = Client.await_tool_call(handle_b, 1_000)
    assert response.result["content"] == [%{"text" => "b done", "type" => "text"}]
    assert Process.alive?(client)
    assert clean_client?(client)
  end

  test "an owner that dies before registration cannot dispatch" do
    {client, _transport} = start_client([])
    :ok = :sys.suspend(client)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, :registration_started)
        Client.start_tool_call(client, "never", %{}, registration_timeout: 1_000)
      end)

    assert_receive :registration_started
    Process.exit(owner, :kill)
    :ok = :sys.resume(client)

    refute_receive {:tool_call_send, _, _, _}, 100
    assert clean_client?(client)
  end

  test "registration timeout fences a queued request from later dispatch" do
    {client, _transport} = start_client([])
    global_name = {__MODULE__, make_ref()}
    :yes = :global.register_name(global_name, client)
    client_name = {:global, global_name}
    :ok = :sys.suspend(client)

    assert {:error, %Error{reason: :registration_timeout}} =
             Client.start_tool_call(client_name, "late", %{}, registration_timeout: 20)

    :ok = :sys.resume(client)
    refute_receive {:tool_call_send, _, _, _}, 100
    assert clean_client?(client)
  end

  test "abandonment after registration removes the request before activation" do
    {client, _transport} = start_client([])
    handle = ToolCall.new(client, self())
    operation = tool_operation("abandoned", 1_000)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:ok, registered_handle} =
             GenServer.call(client, {:register_tool_call, handle, operation, deadline})

    GenServer.cast(client, {:abandon_tool_call, registered_handle})

    assert eventually(fn -> clean_client?(client) end)
    refute_receive {:tool_call_send, _, _, _}, 100
  end

  test "named client handles bind to the resolved process" do
    {client, _transport} = start_client([:ok])
    global_name = {__MODULE__, make_ref()}
    :yes = :global.register_name(global_name, client)

    assert {:ok, handle} = Client.start_tool_call({:global, global_name}, "named", %{})
    assert handle.client == client
    {_dispatch, request} = receive_wire("tools/call")
    respond(client, request["id"], complete("named"))
    assert {:ok, _response} = Client.await_tool_call(handle, 1_000)
  end

  test "owner death during dispatch kills only its worker and keeps the client alive" do
    gate = make_ref()
    {client, _transport} = start_client([{:block, gate}, :ok])
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} = Client.start_tool_call(client, "owned", %{})
        send(parent, {:owned_handle, handle})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned_handle, _handle}
    {dispatch, request} = receive_wire("tools/call")
    dispatch_monitor = Process.monitor(dispatch)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^dispatch_monitor, :process, ^dispatch, :killed}, 1_000
    {_pid, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == request["id"]
    assert eventually(fn -> clean_client?(client) end)
    assert Process.alive?(client)
  end

  test "cancellation during dispatch reports unknown request delivery" do
    gate = make_ref()
    {client, _transport} = start_client([{:block, gate}, :ok])

    assert {:ok, handle} = Client.start_tool_call(client, "blocked", %{})
    {dispatch, _request} = receive_wire("tools/call")
    dispatch_monitor = Process.monitor(dispatch)

    assert {:ok,
            %{
              local: :cancelled,
              request_delivery: :unknown,
              notification_delivery: :accepted,
              remote: :unknown
            }} = Client.cancel_tool_call(handle, "cancel blocked")

    assert_receive {:DOWN, ^dispatch_monitor, :process, ^dispatch, :killed}, 1_000
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle, 1_000)
    assert clean_client?(client)
  end

  test "failed and hung cancellation notifications do not prevent local settlement" do
    for {notification_action, expected} <- [
          {{:error, :offline}, :failed},
          {{:trap_block, make_ref()}, :timeout}
        ] do
      {client, _transport} = start_client([:ok, notification_action])
      assert {:ok, handle} = Client.start_tool_call(client, "cancel", %{})
      {_dispatch, _request} = receive_wire("tools/call")
      assert eventually(fn -> accepted?(client, handle.logical_id) end)

      assert {:ok,
              %{
                local: :cancelled,
                request_delivery: :accepted,
                notification_delivery: ^expected,
                remote: :unknown
              }} = Client.cancel_tool_call(handle, "cancel", notification_timeout: 30)

      assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle, 1_000)
      assert clean_client?(client)
      assert Process.alive?(client)
    end
  end

  test "client termination is not blocked by a hung async cancellation transport" do
    {client, _transport} = start_client([:ok, {:trap_block, make_ref()}])
    assert {:ok, handle} = Client.start_tool_call(client, "shutdown", %{})
    {_dispatch, _request} = receive_wire("tools/call")
    assert eventually(fn -> accepted?(client, handle.logical_id) end)
    client_monitor = Process.monitor(client)

    Client.close(client)

    assert_receive {:DOWN, ^client_monitor, :process, ^client, :normal}, 1_000
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle, 1_000)
    refute_receive {:tool_call_send, _, %{"method" => "notifications/cancelled"}, _}, 100
  end

  test "cancellation before activation proves the request was not sent" do
    {client, _transport} = start_client([])
    handle = ToolCall.new(client, self())
    operation = tool_operation("not-dispatched", 1_000)
    deadline = System.monotonic_time(:millisecond) + 1_000

    assert {:ok, handle} =
             GenServer.call(client, {:register_tool_call, handle, operation, deadline})

    assert {:ok,
            %{
              local: :cancelled,
              request_delivery: :not_sent,
              notification_delivery: :not_needed,
              remote: :unknown
            }} = Client.cancel_tool_call(handle)

    refute_receive {:tool_call_send, _, _, _}, 100
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle, 1_000)
  end

  test "the first terminal event wins response and cancellation races" do
    {client, _transport} = start_client([:ok])
    assert {:ok, result_wins} = Client.start_tool_call(client, "result", %{})
    {_dispatch, request} = receive_wire("tools/call")
    respond(client, request["id"], complete("winner"))
    assert {:ok, _response} = Client.await_tool_call(result_wins, 1_000)
    assert {:error, %Error{reason: :request_not_found}} = Client.cancel_tool_call(result_wins)

    {client, _transport} = start_client([:ok, :ok])
    assert {:ok, cancel_wins} = Client.start_tool_call(client, "cancel", %{})
    {_dispatch, request} = receive_wire("tools/call")
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(cancel_wins)
    respond(client, request["id"], complete("late"))

    assert {:error, %Error{reason: :request_cancelled}} =
             Client.await_tool_call(cancel_wins, 1_000)

    assert Process.alive?(client)
    assert clean_client?(client)
  end

  test "deadline settlement ignores a late reply" do
    {client, _transport} = start_client([:ok, :ok])
    assert {:ok, handle} = Client.start_tool_call(client, "slow", %{}, timeout: 30)
    {_dispatch, request} = receive_wire("tools/call")

    assert {:error, %Error{reason: :request_timeout}} = Client.await_tool_call(handle, 1_000)
    respond(client, request["id"], complete("late"))
    Process.sleep(10)
    assert Process.alive?(client)
    assert clean_client?(client)
  end

  test "logical handle follows MRTR retry and cancels its fresh wire id" do
    {client, _transport} = start_client([:ok, :ok, :ok], %{"sampling" => %{}})

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "resolved"},
           "model" => "test"
         }}
      end)

    assert {:ok, handle} = Client.start_tool_call(client, "search", %{})
    {_dispatch, first} = receive_wire("tools/call")

    respond(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    {_dispatch, retry} = receive_wire("tools/call")
    refute retry["id"] == first["id"]
    assert handle.logical_id == first["id"]
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(handle, "stop retry")
    {_pid, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == retry["id"]
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_tool_call(handle, 1_000)
    assert clean_client?(client)
  end

  test "cancellation stops a blocked MRTR resolver without dispatching a retry" do
    {client, _transport} = start_client([:ok, :ok, :ok], %{"sampling" => %{}})
    parent = self()

    :ok =
      Client.register_sampling_callback(client, fn _params ->
        Process.flag(:trap_exit, true)
        send(parent, {:resolver_started, self()})
        Process.sleep(:infinity)
      end)

    assert {:ok, handle} = Client.start_tool_call(client, "resolve", %{})
    {_dispatch, first} = receive_wire("tools/call")

    respond(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    assert_receive {:resolver_started, resolver}
    request_state = :sys.get_state(client).pending_requests[first["id"]]
    supervisor = request_state.resolver_supervisor
    resolver_monitor = Process.monitor(resolver)
    supervisor_monitor = Process.monitor(supervisor)
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(handle)
    assert_receive {:DOWN, ^resolver_monitor, :process, ^resolver, _reason}, 1_000
    assert_receive {:DOWN, ^supervisor_monitor, :process, ^supervisor, :killed}, 1_000
    {_pid, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == first["id"]
    refute_receive {:tool_call_send, _, %{"method" => "tools/call"}, _}, 100

    assert {:ok, other} = Client.start_tool_call(client, "other", %{})
    {_dispatch, other_request} = receive_wire("tools/call")
    respond(client, other_request["id"], complete("still alive"))
    assert {:ok, _response} = Client.await_tool_call(other, 1_000)
    assert clean_client?(client)
  end

  test "handles are owner-bound and client-bound" do
    {client, _transport} = start_client([{:block, make_ref()}, :ok])
    {other_client, _transport} = start_client([])
    assert {:ok, handle} = Client.start_tool_call(client, "owned", %{})
    {_dispatch, _request} = receive_wire("tools/call")
    parent = self()

    spawn(fn ->
      send(parent, {:foreign_await, Client.await_tool_call(handle, 10)})
      send(parent, {:foreign_cancel, Client.cancel_tool_call(handle)})
    end)

    assert_receive {:foreign_await, {:error, %Error{reason: :request_owner_mismatch}}}
    assert_receive {:foreign_cancel, {:error, %Error{reason: :request_owner_mismatch}}}

    wrong_client = %{handle | client: other_client}
    assert {:error, %Error{reason: :request_not_found}} = Client.cancel_tool_call(wrong_client)
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(handle)
  end

  test "new handle API preserves legacy wire behavior" do
    {client, _transport} = start_client([:ok], %{}, "2025-06-18")
    assert {:ok, handle} = Client.start_tool_call(client, "legacy", %{})
    {_dispatch, request} = receive_wire("tools/call")
    respond(client, request["id"], %{"content" => [%{"type" => "text", "text" => "legacy"}]})
    assert {:ok, response} = Client.await_tool_call(handle, 1_000)
    assert response.result["content"] == [%{"text" => "legacy", "type" => "text"}]
  end

  test "managed progress cleanup cannot remove a later manual registration" do
    gate = make_ref()
    {client, _transport} = start_client([{:block, gate}, :ok])
    first_callback = fn _, _, _ -> :first end
    later_callback = fn _, _, _ -> :later end

    assert {:ok, handle} =
             Client.start_tool_call(client, "progress", %{},
               progress: [token: "shared", callback: first_callback]
             )

    {_dispatch, _request} = receive_wire("tools/call")
    assert :ok = Client.register_progress_callback(client, "shared", later_callback)
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(handle)
    assert :sys.get_state(client).progress_callbacks["shared"] == later_callback
  end

  test "managed progress tokens cannot be owned by two pending calls" do
    gate = make_ref()
    {client, _transport} = start_client([{:block, gate}])
    callback = fn _, _, _ -> :ok end

    assert {:ok, first} =
             Client.start_tool_call(client, "first", %{},
               progress: [token: "duplicate", callback: callback]
             )

    {_dispatch, _request} = receive_wire("tools/call")

    assert {:error, %Error{reason: :invalid_params}} =
             Client.start_tool_call(client, "second", %{},
               progress: [token: "duplicate", callback: callback]
             )

    refute_receive {:tool_call_send, _, %{"params" => %{"name" => "second"}}, _}, 100
    assert {:ok, %{local: :cancelled}} = Client.cancel_tool_call(first)
    assert clean_client?(client)
  end

  defp start_client(actions, capabilities \\ %{}, version \\ "2026-07-28") do
    test_pid = self()

    transport =
      start_supervised!(%{
        id: {Agent, make_ref()},
        start: {Agent, :start_link, [fn -> %{test_pid: test_pid, actions: actions} end]}
      })

    name = "ToolCall-#{System.unique_integer([:positive])}"

    client =
      start_supervised!(%{
        id: {Client, name},
        start:
          {Client, :start_link_server,
           [
             [
               name: String.to_atom(name),
               transport: [layer: ToolCallTransport, name: transport],
               client_info: %{"name" => name, "version" => "1"},
               capabilities: capabilities,
               protocol_version: version
             ]
           ]},
        restart: :temporary
      })

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: if(version == "2026-07-28", do: :modern, else: :legacy),
          negotiated_version: version,
          protocol_version: version,
          negotiation_status: :ready,
          server_capabilities: %{"tools" => %{}}
      }
    end)

    {client, transport}
  end

  defp receive_wire(method) do
    assert_receive {:tool_call_send, pid, message, _opts}, 1_000
    if message["method"] == method, do: {pid, message}, else: receive_wire(method)
  end

  defp receive_tool_requests(0, requests), do: requests

  defp receive_tool_requests(remaining, requests) do
    {_pid, request} = receive_wire("tools/call")
    receive_tool_requests(remaining - 1, Map.put(requests, request["params"]["name"], request))
  end

  defp respond(client, id, result) do
    GenServer.cast(
      client,
      {:response, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
    )
  end

  defp respond_error(client, id, code, message) do
    GenServer.cast(
      client,
      {:response,
       JSON.encode!(%{
         "jsonrpc" => "2.0",
         "id" => id,
         "error" => %{"code" => code, "message" => message}
       })}
    )
  end

  defp complete(text) do
    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => false
    }
  end

  defp tool_operation(name, timeout) do
    Backplane.McpProtocol.Client.Operation.new(%{
      method: "tools/call",
      params: %{"name" => name, "arguments" => %{}},
      timeout: timeout
    })
  end

  defp accepted?(client, logical_id) do
    Enum.any?(:sys.get_state(client).pending_requests, fn {_id, request} ->
      request.logical_id == logical_id and request.dispatch_status == :accepted
    end)
  end

  defp clean_client?(client) do
    state = :sys.get_state(client)
    state.pending_requests == %{} and state.cancellation_workers == %{}
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
