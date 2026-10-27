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
