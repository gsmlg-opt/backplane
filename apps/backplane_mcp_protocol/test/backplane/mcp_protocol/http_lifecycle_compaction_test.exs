defmodule Backplane.McpProtocol.HTTPLifecycleCompactionTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client.OperationSupervisor
  alias Backplane.McpProtocol.HTTP.Lifecycle
  alias Backplane.McpProtocol.Test.HTTPServer
  alias Backplane.McpProtocol.Transport.StreamableHTTP
  alias Elixir.HTTP.RequestCompletion

  setup_all do
    {:ok, _} = Application.ensure_all_started(:backplane_mcp_protocol)
    {:ok, _} = Application.ensure_all_started(:gaoxy_http)
    :ok
  end

  test "repeated real successful requests retain bounded confirmed history and truthful counts" do
    server = HTTPServer.open()
    HTTPServer.stub(server, "POST", "/mcp", &Plug.Conn.resp(&1, 200, "{}"))
    {:ok, transport} = StreamableHTTP.start_link(name: nil, client: self(), url: "http://localhost:#{server.port}/mcp")
    on_exit(fn -> if Process.alive?(transport), do: GenServer.stop(transport) end)
    lifecycle = :sys.get_state(transport).lifecycle

    for _ <- 1..90, do: assert(:ok = StreamableHTTP.send_message(transport, "{}", timeout: 2_000))

    await_state(lifecycle, fn state -> map_size(state.jobs) == 0 and map_size(state.requests) == 0 end)
    assert {:ok, active} = Lifecycle.status(lifecycle)
    assert length(active.resources) <= 67
    assert confirmed_count(active, :http_request) == 90
    assert confirmed_count(active, :http_worker) == 90
    assert Enum.all?(active.resources, &(&1.outcome == :confirmed))
    assert_report_identities(active)
    aggregates = Enum.filter(active.resources, &Map.get(&1.evidence, :aggregate, false))
    assert length(aggregates) == 2

    for resource <- aggregates do
      assert resource.id == {active.activation_id, "confirmed_history:#{resource.scope}"}
    end

    assert {:ok, report} = StreamableHTTP.close(transport, timeout: 1_000)
    assert report.outcome == :confirmed
    assert confirmed_count(report, :http_request) == 90
    assert confirmed_count(report, :http_worker) == 90
    assert_report_identities(report)
    assert {:ok, ^report} = StreamableHTTP.close(transport, timeout: 100)
    GenServer.stop(transport)
  end

  test "active HTTP close cleanup worker keeps an accepted activation-scoped reference identity" do
    server = HTTPServer.open()
    owner = self()

    HTTPServer.expect_once(server, "POST", "/mcp", fn conn ->
      send(owner, :active_headers_blocked)
      receive do: (:release -> Plug.Conn.resp(conn, 200, "{}"))
    end)

    {:ok, transport} =
      StreamableHTTP.start_link(
        name: nil,
        client: self(),
        activation_id: "active-close",
        url: "http://localhost:#{server.port}/mcp"
      )

    on_exit(fn -> if Process.alive?(transport), do: GenServer.stop(transport) end)
    sender = Task.async(fn -> StreamableHTTP.send_message(transport, "{}", timeout: 5_000) end)
    assert_receive :active_headers_blocked, 2_000
    assert {:ok, report} = StreamableHTTP.close(transport, timeout: 2_000)
    assert report.outcome == :confirmed
    assert_report_identities(report)
    workers = Enum.filter(report.resources, &(&1.scope == :http_worker))
    assert length(workers) == 2

    assert Enum.all?(workers, fn resource ->
             {"active-close", id} = resource.id
             is_reference(id) and resource.evidence.barrier == :process_down and resource.evidence.result == :ok
           end)

    assert confirmed_count(report, :http_request) == 1
    Task.await(sender, 1_000)
    GenServer.stop(transport)
  end

  test "compaction requires both original request barrier and actual owned worker DOWN" do
    owner = self()
    tracker = spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> Process.exit(tracker, :kill) end)
    latch = :atomics.new(1, [])
    :atomics.put(latch, 1, 2)
    {:ok, lifecycle} = Lifecycle.start_link(:sse, "both-facts")

    {:ok, worker} =
      Lifecycle.start(lifecycle, fn ->
        {^lifecycle, job} = Process.get(:mcp_http_lifecycle)
        {:ok, id} = Lifecycle.allocation(lifecycle, job)
        :ok = Lifecycle.completion(lifecycle, id, %RequestCompletion{tracker: tracker, latch: latch})
        send(owner, :registered)
        receive do: (:finish -> :ok)
      end)

    assert_receive :registered
    assert map_size(:sys.get_state(lifecycle).requests) == 1
    send(worker, :finish)
    await_state(lifecycle, fn state -> Enum.all?(state.jobs, fn {_, job} -> job.down end) end)
    assert map_size(:sys.get_state(lifecycle).requests) == 1
    send(tracker, :finish)
    await_state(lifecycle, fn state -> map_size(state.requests) == 0 and map_size(state.jobs) == 0 end)
    assert {:ok, report} = Lifecycle.close(lifecycle, timeout: 500)
    assert report.outcome == :confirmed
    assert confirmed_count(report, :http_request) == 1
    GenServer.stop(lifecycle)
  end

  test "missing and unsupported original evidence survives confirmed-history compaction" do
    owner = self()
    {:ok, lifecycle} = Lifecycle.start_link(:sse, "uncertain")

    {:ok, _} =
      Lifecycle.start(lifecycle, fn ->
        {^lifecycle, job} = Process.get(:mcp_http_lifecycle)
        {:ok, missing} = Lifecycle.allocation(lifecycle, job)
        {:ok, unsupported} = Lifecycle.allocation(lifecycle, job)
        :ok = Lifecycle.completion(lifecycle, unsupported, %RequestCompletion{unsupported: :tls_backend})
        send(owner, {:registered, missing, unsupported})
      end)

    assert_receive {:registered, missing, unsupported}
    await_state(lifecycle, fn state -> Enum.all?(state.jobs, fn {_, job} -> job.down end) end)
    assert Map.has_key?(:sys.get_state(lifecycle).requests, missing)
    assert Map.has_key?(:sys.get_state(lifecycle).requests, unsupported)
    assert {:ok, report} = Lifecycle.close(lifecycle, timeout: 500)
    assert report.outcome == :unconfirmed
    assert Enum.any?(report.resources, &(&1.id == {"uncertain", missing} and &1.outcome == :uncertain))
    assert Enum.any?(report.resources, &(&1.id == {"uncertain", unsupported} and &1.outcome == :uncertain))
    GenServer.stop(lifecycle)
  end

  test "owner loss drains unresolved obligations with one supervised worker and one deadline" do
    owner = self()
    tracker = spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> Process.exit(tracker, :kill) end)
    latch = :atomics.new(1, [])
    :atomics.put(latch, 1, 1)

    connection_owner =
      spawn(fn ->
        {:ok, lifecycle} = Lifecycle.start_link(:sse, "owner-loss")
        send(owner, {:lifecycle, lifecycle})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:lifecycle, lifecycle}

    {:ok, _worker} =
      Lifecycle.start(lifecycle, fn ->
        {^lifecycle, job} = Process.get(:mcp_http_lifecycle)

        for _ <- 1..40 do
          {:ok, id} = Lifecycle.allocation(lifecycle, job)
          :ok = Lifecycle.completion(lifecycle, id, %RequestCompletion{tracker: tracker, latch: latch})
        end

        send(owner, :many_registered)
      end)

    assert_receive :many_registered
    await_state(lifecycle, fn state -> Enum.all?(state.jobs, fn {_, job} -> job.down end) end)
    baseline = OperationSupervisor |> Task.Supervisor.children() |> MapSet.new()
    monitor = Process.monitor(lifecycle)
    started = System.monotonic_time(:millisecond)
    send(connection_owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^lifecycle, :normal}, 500
    cleanup = await_cleanup_worker(baseline)
    children = OperationSupervisor |> Task.Supervisor.children() |> MapSet.new()
    assert MapSet.size(MapSet.difference(children, baseline)) == 1
    assert_eventually_down(cleanup, 1_200)
    assert System.monotonic_time(:millisecond) - started < 1_400
  end

  defp await_cleanup_worker(baseline, attempts \\ 100)

  defp await_cleanup_worker(baseline, attempts) when attempts > 0 do
    children = OperationSupervisor |> Task.Supervisor.children() |> MapSet.new()

    case children |> MapSet.difference(baseline) |> MapSet.to_list() do
      [pid] ->
        pid

      [] ->
        Process.sleep(1)
        await_cleanup_worker(baseline, attempts - 1)

      _ ->
        flunk("owner loss spawned more than one cleanup worker")
    end
  end

  defp await_cleanup_worker(_baseline, 0), do: flunk("owner loss did not hand cleanup to its supervisor")

  defp assert_eventually_down(pid, attempts) when attempts > 0 do
    if Process.alive?(pid),
      do:
        (
          Process.sleep(1)
          assert_eventually_down(pid, attempts - 1)
        ),
      else: :ok
  end

  defp assert_eventually_down(_pid, 0), do: flunk("owned cleanup worker survived owner-loss deadline")

  defp assert_report_identities(report) do
    activation = report.activation_id

    for resource <- report.resources do
      assert {^activation, id} = resource.id
      assert is_reference(id) or is_atom(id) or (is_binary(id) and byte_size(id) in 1..1024)
    end
  end

  defp confirmed_count(report, scope) do
    report.resources
    |> Enum.filter(&(&1.scope == scope and &1.outcome == :confirmed))
    |> Enum.reduce(0, fn resource, count -> count + Map.get(resource.evidence, :confirmed_count, 1) end)
  end

  defp await_state(pid, predicate, attempts \\ 200)

  defp await_state(pid, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(pid)

    if predicate.(state),
      do: state,
      else:
        (
          Process.sleep(5)
          await_state(pid, predicate, attempts - 1)
        )
  end

  defp await_state(pid, _predicate, 0) do
    state = :sys.get_state(pid)
    flunk("lifecycle did not compact: #{map_size(state.jobs)} jobs, #{map_size(state.requests)} requests")
  end
end
