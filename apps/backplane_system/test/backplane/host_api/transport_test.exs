defmodule Backplane.HostApi.TransportTest do
  use ExUnit.Case, async: true

  alias Backplane.HostApi.Transport

  setup do
    server = start_supervised!({Transport, name: {:global, {__MODULE__, make_ref()}}})
    owner = self()
    channel = spawn(fn -> channel_loop(owner) end)
    on_exit(fn -> Process.exit(channel, :kill) end)
    :ok = Transport.connect("host", channel, server)
    :ok = Transport.ready("host", channel, %{"service" => 1}, server)
    %{server: server, channel: channel}
  end

  test "acknowledges chunks only after consumer processing and enforces sequence", c do
    assert {:ok, id} = open(c)
    assert_receive {:channel, _, {:host_api_request, ^id, %{"service_revision" => 1}}}

    assert :ok =
             deliver(c, id, %{"type" => "headers", "status" => 200, "headers" => []}, :headers)

    assert_receive {:host_api_frame, ^id, {:headers, 200, []}}
    refute_receive {:channel, _, {:host_api_ack, :headers, :ok}}, 10

    assert {:error, :invalid_response} = deliver(c, id, chunk(0, "early"), :early)
    assert :ok = Transport.ack(id, c.server)
    assert_receive {:channel, _, {:host_api_ack, :headers, :ok}}
    assert :ok = deliver(c, id, chunk(0, "data: hello\n\n"), :chunk)
    assert_receive {:host_api_frame, ^id, {:chunk, "data: hello\n\n"}}
    assert :ok = Transport.ack(id, c.server)
    assert {:error, :invalid_response} = deliver(c, id, chunk(0, "duplicate"), :duplicate)
    assert :ok = deliver(c, id, %{"type" => "done"}, :done)
    assert_receive {:host_api_frame, ^id, :done}
    assert :ok = Transport.ack(id, c.server)
    assert {:error, :invalid_response} = deliver(c, id, chunk(1, "late"), :late)
  end

  test "replacement cancels old requests and stale DOWN cannot retire the new connection", c do
    {:ok, id} = open(c)
    owner = self()
    replacement = spawn(fn -> channel_loop(owner) end)
    on_exit(fn -> Process.exit(replacement, :kill) end)
    assert :ok = Transport.connect("host", replacement, c.server)
    assert_receive {:host_api_error, ^id, :not_connected}
    assert_receive {:channel, _, {:host_api_cancel, ^id}}
    assert :ok = Transport.ready("host", replacement, %{"service" => 2}, c.server)
    Process.exit(c.channel, :kill)
    c = %{c | channel: replacement}
    assert {:ok, new_id} = open(c, 2)
    assert_receive {:channel, ^replacement, {:host_api_request, ^new_id, _}}

    assert {:error, :invalid_response} =
             Transport.deliver(
               "host",
               self(),
               %{"request_id" => new_id, "type" => "error", "code" => "upstream_error"},
               :wrong,
               c.server
             )

    assert :ok = Transport.cancel(new_id, c.server)
  end

  test "consumer death cancels the remote HTTP operation", c do
    owner = self()

    caller =
      spawn(fn ->
        {:ok, id} = open(c)
        send(owner, {:opened, id})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:opened, id}
    Process.exit(caller, :kill)
    assert_receive {:channel, _, {:host_api_cancel, ^id}}
  end

  test "a stalled request times out and cancels without replay", c do
    assert {:ok, id} =
             Transport.open("host", "service", 1, payload(), server: c.server, timeout: 20)

    assert_receive {:channel, _, {:host_api_request, ^id, _}}
    assert_receive {:host_api_error, ^id, :timeout}
    assert_receive {:channel, _, {:host_api_cancel, ^id}}
    refute_receive {:channel, _, {:host_api_request, ^id, _}}, 30
  end

  test "unregistered revisions and oversized requests never reach a host", c do
    assert {:error, :service_unavailable} = open(c, 2)

    assert {:error, :service_unavailable} =
             Transport.open("host", "missing", nil, payload(), server: c.server)

    oversized =
      Map.put(payload(), "body_base64", Base.encode64(:binary.copy("x", 384 * 1024 + 1)))

    assert {:error, :invalid_request} =
             Transport.open("host", "service", 1, oversized, server: c.server)

    refute_receive {:channel, _, {:host_api_request, _, _}}, 10
  end

  test "large responses cross the channel in bounded acknowledged chunks", c do
    {:ok, id} = open(c)
    :ok = deliver(c, id, %{"type" => "headers", "status" => 200, "headers" => []}, :header)
    assert_receive {:host_api_frame, ^id, {:headers, 200, []}}
    :ok = Transport.ack(id, c.server)
    data = :binary.copy("x", 48 * 1024)

    for sequence <- 0..19 do
      assert :ok = deliver(c, id, chunk(sequence, data), sequence)
      assert_receive {:host_api_frame, ^id, {:chunk, ^data}}
      assert :ok = Transport.ack(id, c.server)
    end

    assert :ok = Transport.cancel(id, c.server)
  end

  test "service replacement fails pending work and clears readiness", c do
    {:ok, id} = open(c)
    assert :ok = Transport.invalidate("host", c.channel, c.server)
    assert_receive {:host_api_error, ^id, :service_unavailable}
    assert {:error, :service_unavailable} = open(c)
  end

  test "rejects malformed response headers before handing them to Plug", c do
    {:ok, id} = open(c)

    assert {:error, :invalid_response} =
             deliver(
               c,
               id,
               %{
                 "type" => "headers",
                 "status" => 200,
                 "headers" => [["invalid header", "value"]]
               },
               :bad
             )

    refute_receive {:host_api_frame, ^id, _}, 10
    assert :ok = Transport.cancel(id, c.server)
  end

  defp open(c, revision \\ 1),
    do: Transport.open("host", "service", revision, payload(), server: c.server)

  defp payload,
    do: %{"api" => "openai_embeddings", "headers" => [], "body_base64" => Base.encode64("{}")}

  defp deliver(c, id, frame, ref),
    do: Transport.deliver("host", c.channel, Map.put(frame, "request_id", id), ref, c.server)

  defp chunk(sequence, data),
    do: %{"type" => "chunk", "sequence" => sequence, "data" => Base.encode64(data)}

  defp channel_loop(owner) do
    receive do
      message ->
        send(owner, {:channel, self(), message})
        channel_loop(owner)
    end
  end
end
