defmodule Backplane.McpProtocol.Client.ResourceRequestTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.{Client, MCP.Error, ToolCallTransport}

  test "list and template handles preserve real methods, pagination and metadata" do
    client = start_client()

    for {start, method, key} <- [
          {&Client.start_list_resources/2, "resources/list", "resources"},
          {&Client.start_list_resource_templates/2, "resources/templates/list",
           "resourceTemplates"}
        ] do
      assert {:ok, handle} = start.(client, cursor: "page-2", meta: %{"trace" => "fixture"})
      assert handle.__struct__ == Client.ResourceRequest
      {_worker, wire} = receive_wire(method)
      assert wire["params"]["cursor"] == "page-2"
      assert wire["params"]["_meta"]["trace"] == "fixture"
      result = %{key => [], "nextCursor" => "page-3", "_meta" => %{"unchanged" => true}}
      respond(client, wire["id"], result)
      assert {:ok, response} = Client.await_resource_request(handle, 1_000)
      assert response.result == result
    end
  end

  test "read observation timeout is nonterminal and preserves ordered text/blob contents" do
    client = start_client()
    assert {:ok, handle} = Client.start_read_resource(client, "fixture://read")
    {_worker, wire} = receive_wire("resources/read")
    assert wire["params"]["uri"] == "fixture://read"
    assert {:error, %Error{reason: :request_timeout}} = Client.await_resource_request(handle, 5)

    result = %{
      "contents" => [
        %{"uri" => "fixture://read", "mimeType" => "text/plain", "text" => "汉字\r\n"},
        %{"uri" => "fixture://blob", "mimeType" => "application/octet-stream", "blob" => "AAEC"}
      ]
    }

    respond(client, wire["id"], result)
    assert {:ok, response} = Client.await_resource_request(handle, 1_000)
    assert response.result == result
  end

  test "cancellation stops a blocked dispatch and leaves another resource usable" do
    client = start_client([{:block, make_ref()}, :ok, :ok])
    assert {:ok, cancelled} = Client.start_read_resource(client, "fixture://a")
    {worker, first} = receive_wire("resources/read")
    monitor = Process.monitor(worker)
    assert {:ok, other} = Client.start_read_resource(client, "fixture://b")
    {_worker, second} = receive_wire("resources/read")

    assert {:ok, %{local: :cancelled, request_delivery: :unknown, remote: :unknown}} =
             Client.cancel_resource_request(cancelled)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    {_worker, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == first["id"]
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_resource_request(cancelled)

    result = %{"contents" => []}
    respond(client, second["id"], result)
    assert {:ok, response} = Client.await_resource_request(other, 1_000)
    assert response.result == result
    assert Process.alive?(client)
  end

  test "resource ownership is bound and owner death settles only its request" do
    client = start_client()
    parent = self()

    owner =
      spawn(fn ->
        {:ok, handle} = Client.start_list_resources(client)
        send(parent, {:owned, handle})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned, handle}
    {_worker, wire} = receive_wire("resources/list")

    assert {:error, %Error{reason: :request_owner_mismatch}} =
             Client.await_resource_request(handle, 5)

    assert {:error, %Error{reason: :request_owner_mismatch}} =
             Client.cancel_resource_request(handle)

    send(owner, :finish)
    {_worker, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == wire["id"]
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "registration deadline prevents delayed activation" do
    client = start_client()
    :ok = :sys.suspend(client)

    assert {:error, %Error{reason: :registration_timeout}} =
             Client.start_list_resource_templates(client, registration_timeout: 10)

    :ok = :sys.resume(client)
    refute_receive {:tool_call_send, _, _, _}, 50
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "invalid finite operation budgets are rejected before registration without losing the client" do
    client = start_client()

    for timeout <- [:infinity, 0, -1, nil] do
      assert {:error, %Error{reason: :invalid_params}} =
               Client.start_read_resource(client, "fixture://invalid", timeout: timeout)

      assert Process.alive?(client)
    end

    refute_receive {:tool_call_send, _, _, _}, 20
  end

  test "resource MRTR keeps the logical owner while cancellation targets the fresh wire ID" do
    client = start_client()

    :ok =
      Client.register_sampling_callback(client, fn _ ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "resolved"},
           "model" => "fixture"
         }}
      end)

    assert {:ok, handle} = Client.start_read_resource(client, "fixture://mrtr", timeout: 1_000)
    {_worker, first} = receive_wire("resources/read")

    respond(client, first["id"], %{
      "resultType" => "input_required",
      "inputRequests" => %{
        "sample" => %{
          "method" => "sampling/createMessage",
          "params" => %{"messages" => [], "maxTokens" => 1}
        }
      }
    })

    {_worker, retry} = receive_wire("resources/read")
    refute retry["id"] == first["id"]
    assert handle.logical_id == first["id"]
    assert {:ok, %{local: :cancelled}} = Client.cancel_resource_request(handle)
    {_worker, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == retry["id"]
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_resource_request(handle)
    assert :sys.get_state(client).pending_requests == %{}
  end

  test "events preserve one opaque cursor page and raw ordered descriptor schemas" do
    client = start_client()
    :sys.replace_state(client, &%{&1 | server_capabilities: %{"events" => %{}}})

    assert {:ok, handle} =
             Client.start_list_events(client,
               cursor: "opaque/+page",
               meta: %{"fixture/request" => true}
             )

    {_worker, wire} = receive_wire("events/list")
    assert wire["params"]["cursor"] == "opaque/+page"

    result = %{
      "events" => [
        %{
          "name" => "created",
          "delivery" => ["webhook"],
          "inputSchema" => %{"type" => "object"},
          "payloadSchema" => true
        },
        %{"name" => "updated", "payloadSchema" => false}
      ],
      "nextCursor" => "opaque/next",
      "extra" => [1, 2]
    }

    respond(client, wire["id"], result)
    assert {:ok, response} = Client.await_event_request(handle, 1_000)
    assert response.result === result
  end

  test "event await timeout is nonterminal and cancellation leaves another page pending" do
    client = start_client()
    :sys.replace_state(client, &%{&1 | server_capabilities: %{"events" => %{}}})
    {:ok, first} = Client.start_list_events(client, cursor: "first")
    {_worker, first_wire} = receive_wire("events/list")
    {:ok, second} = Client.start_list_events(client, cursor: "second")
    {_worker, second_wire} = receive_wire("events/list")
    assert {:error, %Error{reason: :request_timeout}} = Client.await_event_request(second, 1)
    assert {:ok, %{local: :cancelled}} = Client.cancel_event_request(first)
    {_worker, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == first_wire["id"]
    assert {:error, %Error{reason: :request_cancelled}} = Client.await_event_request(first)
    result = %{"events" => [], "nextCursor" => "third"}
    respond(client, second_wire["id"], result)
    assert {:ok, response} = Client.await_event_request(second, 1_000)
    assert response.result == result
  end

  test "event registration deadline and owner exit preserve unrelated event work" do
    client = start_client()
    :sys.replace_state(client, &%{&1 | server_capabilities: %{"events" => %{}}})
    :ok = :sys.suspend(client)

    assert {:error, %Error{reason: :registration_timeout}} =
             Client.start_list_events(client, registration_timeout: 5)

    :ok = :sys.resume(client)
    refute_receive {:tool_call_send, _, _, _}, 20
    test = self()

    owner =
      spawn(fn ->
        {:ok, handle} = Client.start_list_events(client)
        send(test, {:event_owned, handle})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:event_owned, handle}
    {_worker, owned_wire} = receive_wire("events/list")

    assert {:error, %Error{reason: :request_owner_mismatch}} =
             Client.await_event_request(handle, 1)

    assert {:error, %Error{reason: :request_owner_mismatch}} = Client.cancel_event_request(handle)
    {:ok, other} = Client.start_list_events(client)
    {_worker, other_wire} = receive_wire("events/list")
    send(owner, :finish)
    {_worker, notification} = receive_wire("notifications/cancelled")
    assert notification["params"]["requestId"] == owned_wire["id"]
    respond(client, other_wire["id"], %{"events" => []})
    assert {:ok, _} = Client.await_event_request(other, 1_000)
  end

  test "events require ready modern negotiation and advertised capability before dispatch" do
    client = start_client()
    assert {:error, %Error{reason: :method_not_found}} = Client.start_list_events(client)
    :sys.replace_state(client, &%{&1 | server_capabilities: %{"events" => %{}}, era: :legacy})
    assert {:error, %Error{reason: :unsupported_operation}} = Client.start_list_events(client)
    assert :sys.get_state(client).pending_requests == %{}
    refute_receive {:tool_call_send, _, _, _}, 20
  end

  test "cancel-aware resource await reports exact verified local retirement" do
    client = start_client([{:block, make_ref()}, :ok])
    test = self()

    owner =
      spawn(fn ->
        control = Client.resource_cancellation_control()
        send(test, {:control, control})
        {:ok, handle} = Client.start_read_resource(client, "fixture://controlled")
        send(test, {:controlled_handle, handle})

        send(
          test,
          {:controlled_result,
           Client.await_resource_request(handle, :infinity, cancellation: control)}
        )
      end)

    assert_receive {:control, control}
    assert_receive {:controlled_handle, handle}
    {worker, wire} = receive_wire("resources/read")
    monitor = Process.monitor(worker)
    assert :ok = Client.cancel_resource_wait(control, "interrupted", timeout: 1_000)
    assert_receive {:controlled_result, {:cancelled, report}}, 1_500
    assert report.local == :cancelled
    assert report.local_cleanup == :confirmed
    assert report.logical_id == handle.logical_id
    assert report.request_id == wire["id"]
    assert is_binary(report.client_incarnation)
    assert report.method == "resources/read"
    assert report.remote == :unknown
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    refute Process.alive?(owner)
  end

  test "cancellation controls cannot select another request after an observation timeout" do
    client = start_client()
    control = Client.resource_cancellation_control()
    {:ok, first} = Client.start_read_resource(client, "fixture://first")
    receive_wire("resources/read")

    assert {:error, %Error{reason: :request_timeout}} =
             Client.await_resource_request(first, 1, cancellation: control)

    {:ok, second} = Client.start_read_resource(client, "fixture://second")
    {_worker, wire} = receive_wire("resources/read")

    assert {:error, %Error{reason: :cancellation_request_mismatch}} =
             Client.await_resource_request(second, 1, cancellation: control)

    respond(client, wire["id"], %{"contents" => []})
    assert {:ok, _} = Client.await_resource_request(second, 1_000)
  end

  test "exact delivered completion reconciles a cancellation that observes request_not_found" do
    client = start_client()
    control = Client.resource_cancellation_control()
    {:ok, handle} = Client.start_read_resource(client, "fixture://race")
    {_worker, wire} = receive_wire("resources/read")
    :ok = Client.cancel_resource_wait(control, "interrupted", timeout: 1_000)
    respond(client, wire["id"], %{"contents" => []})
    assert :sys.get_state(client).pending_requests == %{}
    assert {:ok, response} = Client.await_resource_request(handle, 1_000, cancellation: control)
    assert response.result == %{"contents" => []}
    assert {:ok, identity} = Client.resource_request_identity(handle)
    assert identity.logical_id == handle.logical_id
    assert identity.request_id == wire["id"]
    assert identity.method == "resources/read"
    assert is_binary(identity.client_incarnation)
  end

  test "client mailbox delay does not renew the cancellation cleanup budget" do
    client = start_client()
    control = Client.resource_cancellation_control()
    {:ok, handle} = Client.start_read_resource(client, "fixture://queue-delay")
    receive_wire("resources/read")
    :ok = :sys.suspend(client)
    :ok = Client.cancel_resource_wait(control, "interrupted", timeout: 20)

    spawn(fn ->
      Process.sleep(60)
      :sys.resume(client)
    end)

    assert {:cancelled, report} =
             Client.await_resource_request(handle, 1_000, cancellation: control)

    assert report.notification_delivery == :timeout
    refute_receive {:tool_call_send, _, %{"method" => "notifications/cancelled"}, _}, 20
  end

  test "request_not_found without exact terminal evidence remains an error" do
    client = start_client()
    control = Client.resource_cancellation_control()
    {:ok, handle} = Client.start_read_resource(client, "fixture://consumed")
    {_worker, wire} = receive_wire("resources/read")
    respond(client, wire["id"], %{"contents" => []})
    assert {:ok, _} = Client.await_resource_request(handle, 1_000)
    :ok = Client.cancel_resource_wait(control, "interrupted", timeout: 1_000)

    assert {:error, %Error{reason: :request_not_found}} =
             Client.await_resource_request(handle, 1_000, cancellation: control)
  end

  defp start_client(actions \\ []) do
    test_pid = self()

    transport =
      start_supervised!(%{
        id: {Agent, make_ref()},
        start: {Agent, :start_link, [fn -> %{test_pid: test_pid, actions: actions} end]}
      })

    name = String.to_atom("ResourceRequest-#{System.unique_integer([:positive])}")

    client =
      start_supervised!(%{
        id: name,
        restart: :temporary,
        start:
          {Client, :start_link_server,
           [
             [
               name: name,
               transport: [layer: ToolCallTransport, name: transport],
               client_info: %{"name" => to_string(name), "version" => "1"},
               capabilities: %{"sampling" => %{}},
               protocol_version: "2026-07-28"
             ]
           ]}
      })

    :sys.replace_state(client, fn state ->
      %{
        state
        | era: :modern,
          negotiated_version: "2026-07-28",
          protocol_version: "2026-07-28",
          negotiation_status: :ready,
          server_capabilities: %{"resources" => %{}}
      }
    end)

    client
  end

  defp receive_wire(method) do
    assert_receive {:tool_call_send, worker, wire, _opts}, 1_000
    if wire["method"] == method, do: {worker, wire}, else: receive_wire(method)
  end

  defp respond(client, id, result),
    do:
      GenServer.cast(
        client,
        {:response, JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})}
      )
end
