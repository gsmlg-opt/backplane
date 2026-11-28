defmodule Backplane.CDP.MCP.HeapTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Backplane.CDP.Client
  alias Backplane.CDP.MCP.{Artifacts, Heap, Observer}

  @moduletag :tmp_dir

  defmodule ChromeSocket do
    def init(state), do: {:ok, state}

    def handle_in({bytes, _metadata}, {owner, mode} = state) do
      request = Formata.JSON.decode!(bytes)
      send(owner, {:heap_command, request["method"], request["params"]})
      reply = %{"id" => request["id"], "result" => %{}}

      messages =
        if request["method"] == "HeapProfiler.takeHeapSnapshot" do
          chunks =
            case mode do
              {:chunks, chunks} -> chunks
              :malformed_chunk -> [123]
              :empty -> []
              _ -> ["partial heap data"]
            end

          events =
            Enum.map(
              chunks,
              &%{"method" => "HeapProfiler.addHeapSnapshotChunk", "params" => %{"chunk" => &1}}
            )

          case mode do
            :protocol_error ->
              events ++ [%{"id" => request["id"], "error" => %{"message" => "snapshot failed"}}]

            :disconnect ->
              Process.send_after(self(), :close, 10)
              events

            :hang ->
              events

            _ ->
              events ++ [reply]
          end
        else
          [reply]
        end

      {:push, Enum.map(messages, &{:text, Formata.JSON.encode!(&1)}), state}
    end

    def handle_info(:close, state), do: {:stop, :normal, state}
    def handle_info(_message, state), do: {:ok, state}
  end

  defmodule ChromePlug do
    def init(state), do: state

    def call(conn, state) do
      case conn.request_path do
        "/json/list" ->
          page = %{
            "id" => "page-1",
            "type" => "page",
            "title" => "Heap fixture",
            "url" => "about:blank",
            "webSocketDebuggerUrl" => "ws://127.0.0.1:#{conn.port}/devtools/page/page-1"
          }

          Plug.Conn.send_resp(conn, 200, Formata.JSON.encode!([page]))

        "/devtools/page/page-1" ->
          Plug.Conn.upgrade_adapter(conn, :websocket, {ChromeSocket, state, []})
      end
    end
  end

  setup %{tmp_dir: directory} do
    previous = System.get_env("BACKPLANE_CDP_ARTIFACT_DIR")
    System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", directory)

    on_exit(fn ->
      if previous,
        do: System.put_env("BACKPLANE_CDP_ARTIFACT_DIR", previous),
        else: System.delete_env("BACKPLANE_CDP_ARTIFACT_DIR")
    end)

    :ok
  end

  defp chrome(mode) do
    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {ChromePlug, {self(), mode}}, ip: {127, 0, 0, 1}, port: 0}
      )

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(server, :http)
    %{port: port, pages: %{}, selected: nil, next_id: 1, snapshots: %{}, observers: %{}}
  end

  defp capture(args, state) do
    result = Heap.call("take_heapsnapshot", args, state)
    final_state = elem(result, 2)
    Enum.each(Map.get(final_state, :observers, %{}), fn {_target, pid} -> Observer.stop(pid) end)
    result
  end

  test "streams every chunk beyond the ordinary event queue and publishes a private snapshot", %{
    tmp_dir: directory
  } do
    chunks =
      ["{\"snapshot\":{},\"strings\":["] ++
        Enum.intersperse(Enum.map(1..200, &Formata.JSON.encode!("chunk #{&1}")), ",") ++ ["]}"]

    state = chrome({:chunks, chunks})
    path = Path.join(directory, "snapshot.heapsnapshot")

    assert {:ok, [%{"type" => "text", "text" => "Heap snapshot saved to " <> ^path}], _} =
             capture(%{"pageId" => 1, "filePath" => "snapshot"}, state)

    assert File.read!(path) == IO.iodata_to_binary(chunks)
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert File.ls!(directory) == ["snapshot.heapsnapshot"]
    assert_receive {:heap_command, "HeapProfiler.enable", %{}}
    assert_receive {:heap_command, "HeapProfiler.collectGarbage", %{}}
    assert_receive {:heap_command, "HeapProfiler.takeHeapSnapshot", %{"reportProgress" => false}}
    assert_receive {:heap_command, "HeapProfiler.disable", %{}}
  end

  test "discards partial output after protocol failure", %{tmp_dir: directory} do
    assert {:error, "Chrome protocol error: snapshot failed", _} =
             capture(%{"pageId" => 1, "filePath" => "failed"}, chrome(:protocol_error))

    assert File.ls!(directory) == []
    assert_receive {:heap_command, "HeapProfiler.disable", %{}}
  end

  test "discards partial output after disconnection", %{tmp_dir: directory} do
    assert {:error, "Chrome WebSocket closed during command", _} =
             capture(%{"pageId" => 1, "filePath" => "disconnected"}, chrome(:disconnect))

    assert File.ls!(directory) == []
  end

  test "rejects invalid and empty chunk streams", %{tmp_dir: directory} do
    state = chrome(:malformed_chunk)

    assert {:error, "Chrome returned an invalid heap snapshot chunk", _} =
             capture(%{"pageId" => 1, "filePath" => "invalid"}, state)

    assert File.ls!(directory) == []
  end

  test "rejects an empty snapshot without publishing a file", %{tmp_dir: directory} do
    assert {:error, "Artifact stream is empty", _} =
             capture(%{"pageId" => 1, "filePath" => "empty"}, chrome(:empty))

    assert File.ls!(directory) == []
  end

  test "preserves an existing destination and cleans staging", %{tmp_dir: directory} do
    path = Path.join(directory, "existing.heapsnapshot")
    File.write!(path, "existing content")

    assert {:error, message, _} =
             capture(
               %{"pageId" => 1, "filePath" => "existing"},
               chrome({:chunks, ["new content"]})
             )

    assert message =~ "Cannot publish artifact"
    assert File.read!(path) == "existing content"
    assert File.ls!(directory) == ["existing.heapsnapshot"]
  end

  test "keeps unpublished bytes private and enforces the streaming byte limit", %{
    tmp_dir: directory
  } do
    assert {:error, "Artifact exceeds the 5 byte limit"} =
             Artifacts.stream("bounded", ".heapsnapshot", 5, fn writer ->
               assert :ok = Artifacts.append(writer, "1234")
               [staging] = File.ls!(directory)
               assert String.starts_with?(staging, ".backplane-cdp-")
               assert (File.stat!(Path.join(directory, staging)).mode &&& 0o777) == 0o700

               assert (File.stat!(Path.join([directory, staging, "artifact"])).mode &&& 0o777) ==
                        0o600

               Artifacts.append(writer, "56")
             end)

    assert File.ls!(directory) == []
  end

  test "removes an incomplete artifact when its owning caller dies", %{tmp_dir: directory} do
    owner = self()

    caller =
      spawn(fn ->
        Artifacts.stream("cancelled", ".heapsnapshot", 100, fn writer ->
          :ok = Artifacts.append(writer, "partial")
          send(owner, {:writing, writer})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:writing, writer}
    monitor = Process.monitor(writer)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}
    assert File.ls!(directory) == []
  end

  test "cleans staged bytes when the bounded Chrome command times out", %{tmp_dir: directory} do
    state = chrome(:hang)

    result =
      Artifacts.stream("timeout", ".heapsnapshot", 100, fn writer ->
        Client.with_connection(
          state.port,
          "page-1",
          fn connection ->
            case Client.stream_command(
                   connection,
                   "HeapProfiler.takeHeapSnapshot",
                   %{},
                   "HeapProfiler.addHeapSnapshotChunk",
                   &Artifacts.append(writer, &1["chunk"])
                 ) do
              {:ok, _} -> :ok
              error -> error
            end
          end,
          200
        )
      end)

    assert result == {:error, "Chrome command timed out"}
    assert File.ls!(directory) == []
  end

  test "rejects unsupported options and paths outside the operator artifact directory", %{
    tmp_dir: directory
  } do
    state = chrome(:empty)

    assert {:error, "Unsupported heap snapshot options", _} =
             Heap.call(
               "take_heapsnapshot",
               %{"filePath" => "snapshot", "arbitrary" => true},
               state
             )

    assert {:error, "A heap snapshot filePath is required", _} =
             Heap.call("take_heapsnapshot", %{}, state)

    assert {:error,
            "Choose a file directly inside cdp.artifact_dir (host config) or BACKPLANE_CDP_ARTIFACT_DIR",
            _} =
             capture(%{"pageId" => 1, "filePath" => "../outside"}, state)

    assert File.ls!(directory) == []
    refute_receive {:heap_command, "HeapProfiler.takeHeapSnapshot", _}
  end
end
