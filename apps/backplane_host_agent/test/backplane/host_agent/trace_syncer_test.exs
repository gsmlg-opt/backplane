defmodule Backplane.HostAgent.TraceSyncerTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.TraceSyncer

  @moduletag :tmp_dir

  defmodule FakeChannel do
    def push(channel, event, payload, _timeout \\ 5_000) do
      send(channel, {:trace_push, event, payload})

      case Process.get({__MODULE__, :reply}) do
        nil ->
          {:ok,
           %{
             "ok" => true,
             "result" => %{
               "items" => Enum.map(payload["items"], &%{"seq" => &1["seq"], "status" => "ok"})
             }
           }}

        reply ->
          reply
      end
    end
  end

  test "drains trace items with contract payload and advances cursor on ok acks", %{
    tmp_dir: tmp_dir
  } do
    write_trace_file(tmp_dir, [
      trace_item(1, "backplane.host_agent.mcp.request.stop"),
      trace_item(2, "backplane.host_agent.memory.call.stop")
    ])

    assert {:ok, %{"drained" => 2}} =
             TraceSyncer.drain_once(dir: tmp_dir, channel: self(), channel_module: FakeChannel)

    assert_receive {:trace_push, "trace_sync",
                    %{
                      "protocol" => "host_trace.v1",
                      "items" => [%{"seq" => 1}, %{"seq" => 2}]
                    }}

    assert %{"seq" => 2} = read_cursor(tmp_dir)
  end

  test "holds cursor on error ack and push failure", %{tmp_dir: tmp_dir} do
    write_trace_file(tmp_dir, [trace_item(1, "one"), trace_item(2, "two")])

    Process.put(
      {FakeChannel, :reply},
      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "items" => [
             %{"seq" => 1, "status" => "error", "error" => "bad"},
             %{"seq" => 2, "status" => "ok"}
           ]
         }
       }}
    )

    assert {:ok, %{"drained" => 2}} =
             TraceSyncer.drain_once(dir: tmp_dir, channel: self(), channel_module: FakeChannel)

    refute File.exists?(Path.join(tmp_dir, "cursor.json"))

    Process.put({FakeChannel, :reply}, {:error, :disconnected})

    assert {:error, :disconnected} =
             TraceSyncer.drain_once(dir: tmp_dir, channel: self(), channel_module: FakeChannel)

    refute File.exists?(Path.join(tmp_dir, "cursor.json"))
  end

  test "skips cleanly when disconnected", %{tmp_dir: tmp_dir} do
    write_trace_file(tmp_dir, [trace_item(1, "one")])

    assert {:ok, %{"drained" => 0, "status" => "disconnected"}} =
             TraceSyncer.drain_once(dir: tmp_dir, channel_provider: __MODULE__.NoChannel)
  end

  defmodule NoChannel do
    def channel, do: nil
  end

  defp write_trace_file(dir, items) do
    body = Enum.map_join(items, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join(dir, "traces-2026-07-06.jsonl"), body)
  end

  defp trace_item(seq, event) do
    %{
      "seq" => seq,
      "trace_id" => String.duplicate("a", 32),
      "span_id" => String.duplicate("b", 16),
      "parent_id" => nil,
      "event" => event,
      "measurements" => %{},
      "metadata" => %{},
      "occurred_at" => "2026-07-06T00:00:00Z"
    }
  end

  defp read_cursor(dir) do
    dir
    |> Path.join("cursor.json")
    |> File.read!()
    |> Jason.decode!()
  end
end
