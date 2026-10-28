defmodule Backplane.McpProtocol.Client.ResourceRequestSTDIOTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client

  @fixture """
  import json, sys
  for line in sys.stdin:
      message = json.loads(line)
      with open(sys.argv[1], 'a') as log:
          log.write(json.dumps(message) + '\\n')
      method = message.get('method')
      if method == 'server/discover':
          result = {'resultType': 'complete', 'supportedVersions': ['2026-07-28'],
                    'capabilities': {'resources': {}}, 'ttlMs': 0, 'cacheScope': 'private'}
      elif method == 'resources/list':
          result = {'resultType': 'complete', 'resources': []}
      else:
          continue
      print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': result}), flush=True)
  """

  for {label, delay, budget} <- [{"live budget", 20, 500}, {"expired budget", 100, 30}] do
    @tag :tmp_dir
    test "queued STDIO resource is fenced with #{label}", %{tmp_dir: tmp_dir} do
      {client, transport, log} = start_client(tmp_dir)
      :ok = :sys.suspend(transport)
      {:ok, handle} = Client.start_read_resource(client, "fixture://queued")
      await_send(transport)

      spawn(fn ->
        Process.sleep(unquote(delay))
        :sys.resume(transport)
      end)

      assert {:ok, report} =
               Client.cancel_resource_request(handle, "interrupted",
                 verified: true,
                 notification_timeout: unquote(budget)
               )

      assert report.local == :cancelled

      if unquote(delay) < unquote(budget) do
        assert report.local_cleanup == :confirmed
        assert report.cleanup_evidence.transport == :confirmed
      else
        assert report.local_cleanup == :uncertain
      end

      Process.sleep(unquote(delay) + 30)
      refute Enum.any?(messages(log), &(&1["method"] == "resources/read"))

      if unquote(delay) > unquote(budget) do
        refute Enum.any?(messages(log), &(&1["method"] == "notifications/cancelled"))
      end

      assert {:ok, other} = Client.start_list_resources(client)
      assert {:ok, _} = Client.await_resource_request(other, 1_000)
    end
  end

  @tag :tmp_dir
  test "accepted pending STDIO resource has a verified barrier without closing shared transport",
       %{tmp_dir: tmp_dir} do
    {client, _transport, log} = start_client(tmp_dir)
    {:ok, handle} = Client.start_read_resource(client, "fixture://accepted")
    await_message(log, "resources/read")

    assert {:ok, %{local_cleanup: :confirmed, cleanup_evidence: %{transport: :confirmed}}} =
             Client.cancel_resource_request(handle, "interrupted",
               verified: true,
               notification_timeout: 500
             )

    assert {:ok, other} = Client.start_list_resources(client)
    assert {:ok, _} = Client.await_resource_request(other, 1_000)
  end

  @tag :tmp_dir
  test "completed tracked STDIO request retires through barrier without replay or cancellation",
       %{tmp_dir: tmp_dir} do
    {client, _transport, log} = start_client(tmp_dir)
    {:ok, handle} = Client.start_list_resources(client, track_retirement: true)
    assert {:ok, response} = Client.await_resource_request(handle, 1_000)
    assert response.result == %{"resultType" => "complete", "resources" => []}

    assert {:ok, %{local_cleanup: :confirmed, terminal: :completed}} =
             Client.retire_resource_request(handle)

    assert Enum.count(messages(log), &(&1["method"] == "resources/list")) == 1
    refute Enum.any?(messages(log), &(&1["method"] == "notifications/cancelled"))
    {:ok, next} = Client.start_list_resources(client)
    assert {:ok, _} = Client.await_resource_request(next, 1_000)
  end

  defp start_client(tmp_dir) do
    log = Path.join(tmp_dir, "messages.jsonl")
    name = String.to_atom("ResourceSTDIO#{System.unique_integer([:positive])}")

    supervisor =
      start_supervised!(
        {Client,
         name: name,
         one_shot: true,
         transport:
           {:stdio,
            command: System.find_executable("python3"),
            args: ["-u", "-c", @fixture, log],
            cleanup: :verified},
         protocol_version: "2026-07-28",
         client_info: %{"name" => "fixture", "version" => "1"},
         capabilities: %{}}
      )

    on_exit(fn ->
      if Process.alive?(supervisor), do: Client.close_connection(supervisor, timeout: 1_000)
    end)

    assert :ok = Client.await_ready(name, timeout: 2_000)
    {name, GenServer.whereis(:sys.get_state(name).transport.name), log}
  end

  defp messages(log),
    do: log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  defp await_message(log, method, attempts \\ 100)
  defp await_message(_log, _method, 0), do: flunk("STDIO request was not dispatched")

  defp await_message(log, method, attempts) do
    if Enum.any?(messages(log), &(&1["method"] == method)) do
      :ok
    else
      Process.sleep(5)
      await_message(log, method, attempts - 1)
    end
  end

  defp await_send(transport, attempts \\ 100)
  defp await_send(_transport, 0), do: flunk("STDIO request was not queued")

  defp await_send(transport, attempts) do
    {:messages, queued} = Process.info(transport, :messages)

    if Enum.any?(queued, &match?({:"$gen_call", _, {:send, _}}, &1)) or
         Enum.any?(queued, &match?({:"$gen_call", _, {:send, _, _}}, &1)) do
      :ok
    else
      Process.sleep(5)
      await_send(transport, attempts - 1)
    end
  end
end
