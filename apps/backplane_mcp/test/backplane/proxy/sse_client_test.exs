defmodule Backplane.Proxy.SSEClientTest do
  use ExUnit.Case

  alias Backplane.Proxy.SSEClient

  setup do
    start_supervised!(Backplane.Test.MockSseMcpServer)

    bandit =
      start_supervised!(
        {Bandit, plug: Backplane.Test.MockSseMcpServer.Router, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    %{port: port}
  end

  describe "connect/3" do
    test "connects and receives endpoint event", %{port: port} do
      {:ok, ref, pid} = SSEClient.connect("http://127.0.0.1:#{port}/sse", [], self())
      assert_receive {:sse_event, ^ref, %{event: "endpoint", data: data}}, 5000
      assert String.starts_with?(data, "/message")
      SSEClient.close(ref, pid)
    end

    test "receives message events pushed by server", %{port: port} do
      {:ok, ref, pid} = SSEClient.connect("http://127.0.0.1:#{port}/sse", [], self())
      assert_receive {:sse_event, ^ref, %{event: "endpoint", data: endpoint}}, 5000

      session_id = endpoint |> String.split("sessionId=") |> List.last() |> String.to_integer()
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      Backplane.Test.MockSseMcpServer.push_event(session_id, response)

      assert_receive {:sse_event, ^ref, %{event: "message", data: _}}, 5000
      SSEClient.close(ref, pid)
    end

    test "notifies parent on connection close", %{port: port} do
      {:ok, ref, _pid} = SSEClient.connect("http://127.0.0.1:#{port}/sse", [], self())
      assert_receive {:sse_event, ^ref, %{event: "endpoint", data: endpoint}}, 5000

      session_id = endpoint |> String.split("sessionId=") |> List.last() |> String.to_integer()
      Backplane.Test.MockSseMcpServer.close_session(session_id)

      assert_receive {:sse_closed, ^ref, _reason}, 5000
    end
  end
end
