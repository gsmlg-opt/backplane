defmodule Backplane.Proxy.UpstreamConcurrencyTest do
  use BackplaneMcp.DataCase, async: false

  alias Backplane.MCP.Dispatch
  alias Backplane.McpProtocol.Client.ToolCall
  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.Proxy.{ClientPool, Pool, Upstream}
  alias Backplane.Registry.ToolRegistry

  setup do
    :ets.delete_all_objects(:backplane_tools)
    cleanup_upstreams()

    on_exit(fn ->
      cleanup_upstreams()
      :ets.delete_all_objects(:backplane_tools)
    end)

    :ok
  end

  describe "non-blocking concurrent execution and control responsiveness" do
    for {era_label, mode, protocol_version} <- [
          {"legacy 2025-11-25", :legacy, "2025-11-25"},
          {"modern 2026-07-28", :modern, "2026-07-28"}
        ] do
      test "blocked slow call does not prevent fast call, status, or health checks (#{era_label})" do
        mode = unquote(mode)
        protocol_version = unquote(protocol_version)
        test_pid = self()

        call_result = fn request ->
          case get_in(request, ["params", "name"]) do
            "slow" ->
              send(test_pid, {:slow_entered, self()})

              receive do
                :release_slow -> tool_payload(mode, "slow-done")
              after
                5_000 -> tool_payload(mode, "slow-timed-out")
              end

            "fast" ->
              tool_payload(mode, "fast-done")
          end
        end

        url = start_http_fixture(mode: mode, call_result: call_result)

        pid =
          start_test_upstream(
            http_config(unique_name("nonblock-#{mode}"), url,
              protocol_version: protocol_version,
              max_concurrent_calls: 4
            )
          )

        assert eventually(fn -> Upstream.status(pid).status == :connected end)
        drain_upstream_requests()

        slow_task = Task.async(fn -> Upstream.forward(pid, "slow", %{}, 5_000) end)
        assert_receive {:slow_entered, slow_handler}, 2_000

        # Status responds immediately while slow call is blocked
        assert %{status: :connected, in_flight_calls: 1, queued_calls: 0} = Upstream.status(pid)

        # Independent fast call completes while slow call is still blocked
        assert {:ok, fast_result} = Upstream.forward(pid, "fast", %{}, 2_000)
        assert [%{"text" => "fast-done"}] = fast_result["content"]

        # Health check completes while slow call is still blocked
        send(pid, :health_ping)

        case unquote(mode) do
          :legacy ->
            assert %{method: "ping"} = receive_upstream_request("ping")

          :modern ->
            assert %{method: "tools/list"} = receive_upstream_request("tools/list")
        end

        assert eventually(fn -> not is_nil(Upstream.status(pid).last_pong_at) end)

        # Slow call is still blocked until we explicitly release it
        assert Upstream.status(pid).in_flight_calls == 1
        send(slow_handler, :release_slow)

        assert {:ok, slow_result} = Task.await(slow_task, 2_000)
        assert [%{"text" => "slow-done"}] = slow_result["content"]
        assert eventually(fn -> Upstream.status(pid).in_flight_calls == 0 end)
      end
    end

    for {mode, version, operation, method} <- [
          {:legacy, "2025-11-25", :health_ping, "ping"},
          {:modern, "2026-07-28", :health_ping, "tools/list"},
          {:legacy, "2025-11-25", :refresh, "tools/list"},
          {:modern, "2026-07-28", :refresh, "tools/list"}
        ] do
      test "blocked #{operation} keeps tool completion, cancellation and status responsive (#{mode})" do
        mode = unquote(mode)
        owner = self()
        armed = start_supervised!({Agent, fn -> false end})

        gate = fn ->
          if Agent.get(armed, & &1) do
            send(owner, {:control_entered, self()})

            receive do
              :release_control -> :ok
            after
              2_000 -> :ok
            end
          end
        end

        call_result = fn request ->
          send(owner, {:tool_entered, get_in(request, ["params", "name"]), self()})

          receive do
            :release_tool -> tool_payload(mode, "done")
          after
            2_000 -> tool_payload(mode, "timeout")
          end
        end

        url =
          start_http_fixture(
            mode: mode,
            delays: %{unquote(method) => gate},
            call_result: call_result
          )

        pid =
          start_test_upstream(
            http_config(unique_name("control-#{mode}"), url,
              protocol_version: unquote(version),
              max_concurrent_calls: 2
            )
          )

        assert eventually(fn -> Upstream.status(pid).status == :connected end)
        first = Task.async(fn -> Upstream.forward(pid, "first", %{}, 5_000) end)
        assert_receive {:tool_entered, "first", first_handler}, 2_000
        cancel_ref = make_ref()

        sibling =
          Task.async(fn ->
            Upstream.forward(pid, "sibling", %{}, timeout: 5_000, request_ref: cancel_ref)
          end)

        assert_receive {:tool_entered, "sibling", sibling_handler}, 2_000
        Agent.update(armed, fn _ -> true end)
        send(pid, unquote(operation))
        assert_receive {:control_entered, control_handler}, 2_000
        send(first_handler, :release_tool)
        assert {:ok, _result} = Task.await(first, 500)
        assert %{status: :connected} = GenServer.call(pid, :status, 200)
        Upstream.cancel_forward(pid, cancel_ref)
        assert {:error, "Upstream call cancelled"} = Task.await(sibling, 500)
        assert %{in_flight_calls: 0} = GenServer.call(pid, :status, 200)

        for _ <- 1..20, do: send(pid, unquote(operation))
        _status = GenServer.call(pid, :status, 200)
        refute_receive {:control_entered, _}, 50
        send(control_handler, :release_control)
        send(sibling_handler, :release_tool)
        assert_receive {:control_entered, coalesced_handler}, 1_000
        send(coalesced_handler, :release_control)
        assert eventually(fn -> :sys.get_state(pid).control_operation == nil end)
        refute_receive {:control_entered, _}, 50
      end
    end

    test "queued legacy health runs before later refreshes" do
      owner = self()
      armed = start_supervised!({Agent, fn -> false end})

      gate = fn ->
        if Agent.get(armed, & &1) do
          send(owner, {:refresh_started, self()})

          receive do
            :release_refresh -> :ok
          after
            2_000 -> :ok
          end
        end
      end

      url = start_http_fixture(mode: :legacy, delays: %{"tools/list" => gate})

      pid =
        start_test_upstream(
          http_config(unique_name("control-order"), url, protocol_version: "2025-11-25")
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      Agent.update(armed, fn _ -> true end)
      Upstream.refresh(pid)
      assert_receive {:refresh_started, first}, 1_000
      drain_upstream_requests()

      send(pid, :health_ping)
      for _ <- 1..3, do: Upstream.refresh(pid)
      assert %{last_pong_at: nil} = Upstream.status(pid)
      send(first, :release_refresh)

      assert_receive {:upstream_request, %{method: method}}, 1_000
      assert method == "ping"
      assert_receive {:refresh_started, second}, 1_000
      assert %{last_pong_at: pong_at} = Upstream.status(pid)
      assert is_integer(pong_at)
      send(second, :release_refresh)
      assert eventually(fn -> :sys.get_state(pid).control_operation == nil end)
      refute_receive {:refresh_started, _}, 50
    end

    @tag :stdio
    @tag :tmp_dir
    test "blocked slow stdio call does not block fast call, status, or health on capable stdio server",
         %{tmp_dir: tmp_dir} do
      gate_file = Path.join(tmp_dir, "release_slow")
      started_file = Path.join(tmp_dir, "slow_started")
      script = write_multiplex_stdio_server(tmp_dir, started_file, gate_file)

      pid =
        start_test_upstream(%{
          name: unique_name("stdio-mux"),
          prefix: unique_name("stdiomux"),
          transport: "stdio",
          protocol_version: "2025-11-25",
          command: "bash",
          args: [script],
          env: %{},
          max_concurrent_calls: 4
        })

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      slow_task = Task.async(fn -> Upstream.forward(pid, "slow", %{}, 5_000) end)
      assert eventually(fn -> File.exists?(started_file) end)

      assert %{status: :connected, in_flight_calls: 1, queued_calls: 0} = Upstream.status(pid)

      assert {:ok, fast_result} = Upstream.forward(pid, "fast", %{}, 2_000)
      assert [%{"text" => "stdio-fast"}] = fast_result["content"]

      send(pid, :health_ping)
      assert eventually(fn -> not is_nil(Upstream.status(pid).last_pong_at) end)

      File.write!(gate_file, "go")
      assert {:ok, slow_result} = Task.await(slow_task, 2_000)
      assert [%{"text" => "stdio-slow"}] = slow_result["content"]
      assert eventually(fn -> Upstream.status(pid).in_flight_calls == 0 end)
    end
  end

  describe "bounded catalog operation lifecycle" do
    test "catalog pages share one deadline and a timed-out worker is retired" do
      owner = self()
      armed = start_supervised!({Agent, fn -> false end})

      catalog = fn cursor ->
        if Agent.get(armed, & &1) do
          send(owner, {:catalog_page, cursor, self()})

          case cursor do
            nil ->
              Process.sleep(160)
              %{"tools" => [], "nextCursor" => "second"}

            "second" ->
              receive do
                :release_page -> %{"tools" => []}
              after
                1_000 -> %{"tools" => []}
              end
          end
        else
          %{"tools" => [%{"name" => "original", "inputSchema" => %{"type" => "object"}}]}
        end
      end

      url = start_http_fixture(mode: :modern, catalog: catalog)

      pid =
        start_test_upstream(
          http_config(unique_name("catalog-deadline"), url,
            protocol_version: "2026-07-28",
            timeout: 300
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      Agent.update(armed, fn _ -> true end)
      Upstream.refresh(pid)
      assert_receive {:catalog_page, nil, _}, 1_000
      operation = :sys.get_state(pid).control_operation
      monitor = Process.monitor(operation.pid)
      assert_receive {:catalog_page, "second", handler}, 1_000
      assert_receive {:DOWN, ^monitor, :process, _, _}, 220
      assert eventually(fn -> :sys.get_state(pid).control_operation == nil end)
      assert %{status: :connected, tool_count: 1} = Upstream.status(pid)
      send(handler, :release_page)
      refute_receive {:catalog_page, _, _}, 50
    end

    test "a replaced protocol client cannot publish an old catalog result" do
      owner = self()
      armed = start_supervised!({Agent, fn -> false end})

      catalog = fn _cursor ->
        if Agent.get(armed, & &1) do
          send(owner, {:replacement_catalog_blocked, self()})

          receive do
            :release_page -> %{"tools" => []}
          after
            2_000 -> %{"tools" => []}
          end
        else
          %{"tools" => [%{"name" => "current", "inputSchema" => %{"type" => "object"}}]}
        end
      end

      url = start_http_fixture(mode: :modern, catalog: catalog)

      pid =
        start_test_upstream(
          http_config(unique_name("catalog-client-replaced"), url, protocol_version: "2026-07-28")
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      Agent.update(armed, fn _ -> true end)
      Upstream.refresh(pid)
      assert_receive {:replacement_catalog_blocked, handler}, 1_000
      operation = :sys.get_state(pid).control_operation
      monitor = Process.monitor(operation.pid)
      Agent.update(armed, fn _ -> false end)
      Process.exit(operation.client, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 1_000
      send(handler, :release_page)

      assert eventually(fn ->
               state = :sys.get_state(pid)

               state.status == :connected and
                 GenServer.whereis(state.client) != operation.client
             end)

      send(pid, {:control_result, operation.ref, {:ok, []}})
      assert %{status: :connected, tool_count: 1} = Upstream.status(pid)
      assert :sys.get_state(pid).control_operation == nil
    end

    for settlement <- [:timeout, :worker_down] do
      test "stale #{settlement} cannot settle control for a replaced client" do
        owner = self()
        armed = start_supervised!({Agent, fn -> false end})

        catalog = fn _cursor ->
          if Agent.get(armed, & &1) do
            send(owner, {:stale_settlement_catalog, self()})

            receive do
              :release_page -> %{"tools" => []}
            after
              2_000 -> %{"tools" => []}
            end
          else
            %{"tools" => [%{"name" => "current", "inputSchema" => %{"type" => "object"}}]}
          end
        end

        url = start_http_fixture(mode: :modern, catalog: catalog)

        pid =
          start_test_upstream(
            http_config(unique_name("stale-control-settlement"), url,
              protocol_version: "2026-07-28"
            )
          )

        assert eventually(fn -> Upstream.status(pid).status == :connected end)
        Agent.update(armed, fn _ -> true end)
        Upstream.refresh(pid)
        assert_receive {:stale_settlement_catalog, handler}, 1_000
        state = :sys.get_state(pid)
        operation = state.control_operation
        :ok = :sys.suspend(pid)

        event =
          case unquote(settlement) do
            :timeout -> {:control_timeout, operation.ref}
            :worker_down -> {:DOWN, operation.monitor, :process, operation.pid, :killed}
          end

        send(pid, event)
        Agent.update(armed, fn _ -> false end)
        Process.exit(operation.client, :kill)

        replaced? =
          eventually(fn ->
            replacement = GenServer.whereis(state.client)
            is_pid(replacement) and replacement != operation.client
          end)

        :ok = :sys.resume(pid)
        assert replaced?
        assert %{status: :disconnected, tool_count: 0} = Upstream.status(pid)
        assert :sys.get_state(pid).control_operation == nil
        send(handler, :release_page)
        assert eventually(fn -> Upstream.status(pid).status == :connected end)
        assert %{tool_count: 1} = Upstream.status(pid)
      end
    end

    test "worker crash, stale completion and stopping preserve registry ownership" do
      owner = self()
      armed = start_supervised!({Agent, fn -> false end})

      catalog = fn _cursor ->
        if Agent.get(armed, & &1) do
          send(owner, {:catalog_blocked, self()})

          receive do
            :release_page -> %{"tools" => []}
          after
            2_000 -> %{"tools" => []}
          end
        else
          %{"tools" => [%{"name" => "original", "inputSchema" => %{"type" => "object"}}]}
        end
      end

      url = start_http_fixture(mode: :modern, catalog: catalog)

      pid =
        start_test_upstream(
          http_config(unique_name("catalog-lifecycle"), url, protocol_version: "2026-07-28")
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      Agent.update(armed, fn _ -> true end)
      Upstream.refresh(pid)
      assert_receive {:catalog_blocked, first_handler}, 1_000
      first = :sys.get_state(pid).control_operation
      Process.exit(first.pid, :kill)
      assert eventually(fn -> :sys.get_state(pid).control_operation == nil end)
      send(pid, {:control_result, first.ref, {:ok, []}})
      assert %{tool_count: 1} = Upstream.status(pid)
      send(first_handler, :release_page)

      Upstream.refresh(pid)
      assert_receive {:catalog_blocked, second_handler}, 1_000
      second = :sys.get_state(pid).control_operation
      monitor = Process.monitor(second.pid)
      assert :ok = Upstream.prepare_stop(pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 500
      send(pid, {:control_result, second.ref, {:ok, []}})
      assert %{status: :disconnected, tool_count: 0} = Upstream.status(pid)
      assert :sys.get_state(pid).control_operation == nil
      assert :sys.get_state(pid).pending_controls == []
      send(second_handler, :release_page)
    end
  end

  describe "deadline enforcement and zero-invocation expiry" do
    test "expired queued call is never submitted even when caller remains alive after timeout" do
      test_pid = self()
      invocations = start_supervised!({Agent, fn -> %{} end})

      call_result = fn request ->
        tool_name = get_in(request, ["params", "name"])
        Agent.update(invocations, &Map.update(&1, tool_name, 1, fn count -> count + 1 end))

        case tool_name do
          "blocker" ->
            send(test_pid, {:blocker_entered, self()})

            receive do
              :release_blocker -> tool_payload(:modern, "blocker-done")
            after
              5_000 -> tool_payload(:modern, "blocker-timeout")
            end

          other ->
            tool_payload(:modern, "ok:#{other}")
        end
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      pid =
        start_test_upstream(
          http_config(unique_name("queue-expiry"), url,
            protocol_version: "2026-07-28",
            max_concurrent_calls: 1,
            max_queued_calls: 4
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      # Saturate the single execution slot
      blocker_task = Task.async(fn -> Upstream.forward(pid, "blocker", %{}, 5_000) end)
      assert_receive {:blocker_entered, blocker_handler}, 2_000
      assert Upstream.status(pid).in_flight_calls == 1

      # Enqueue a call from a caller that intentionally stays alive after timing out
      alive_caller =
        spawn(fn ->
          result = Upstream.forward(pid, "never_submit", %{}, 40)
          send(test_pid, {:alive_caller_result, result})

          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(alive_caller), do: send(alive_caller, :stop) end)

      assert_receive {:alive_caller_result, {:error, timeout_msg}}, 1_000
      assert timeout_msg =~ "timeout"
      assert Process.alive?(alive_caller)
      assert eventually(fn -> Upstream.status(pid).queued_calls == 0 end)

      # Release blocker and run a probe to ensure queue drained cleanly
      send(blocker_handler, :release_blocker)
      assert {:ok, _} = Task.await(blocker_task, 2_000)
      assert {:ok, _} = Upstream.forward(pid, "probe", %{}, 2_000)

      # Assert ZERO upstream invocations for the expired queued call
      counts = Agent.get(invocations, & &1)
      assert Map.get(counts, "never_submit", 0) == 0
      assert Map.get(counts, "blocker", 0) == 1
      assert Map.get(counts, "probe", 0) == 1
    end

    test "call expiring while waiting in upstream mailbox is never submitted even if caller stays alive" do
      test_pid = self()
      invocations = start_supervised!({Agent, fn -> %{} end})

      call_result = fn request ->
        tool_name = get_in(request, ["params", "name"])
        Agent.update(invocations, &Map.update(&1, tool_name, 1, fn count -> count + 1 end))
        tool_payload(:modern, "ok:#{tool_name}")
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      pid =
        start_test_upstream(
          http_config(unique_name("mailbox-expiry"), url,
            protocol_version: "2026-07-28",
            max_concurrent_calls: 2
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      :ok = :sys.suspend(pid)

      alive_caller =
        spawn(fn ->
          result = Upstream.forward(pid, "mailbox_expired", %{}, 30)
          send(test_pid, {:mailbox_caller_result, result})

          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(alive_caller), do: send(alive_caller, :stop) end)

      assert_receive {:mailbox_caller_result, {:error, timeout_msg}}, 1_000
      assert timeout_msg =~ "timeout"
      assert Process.alive?(alive_caller)

      :ok = :sys.resume(pid)
      assert {:ok, _} = Upstream.forward(pid, "after_resume", %{}, 2_000)

      counts = Agent.get(invocations, & &1)
      assert Map.get(counts, "mailbox_expired", 0) == 0
      assert Map.get(counts, "after_resume", 0) == 1
    end

    test "already-expired absolute deadline_ms fails immediately with zero invocations" do
      invocations = start_supervised!({Agent, fn -> 0 end})

      call_result = fn _request ->
        Agent.update(invocations, &(&1 + 1))
        tool_payload(:modern, "should-not-run")
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      pid =
        start_test_upstream(
          http_config(unique_name("past-deadline"), url, protocol_version: "2026-07-28")
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      past_deadline = System.monotonic_time(:millisecond) - 10

      assert {:error, msg} =
               Upstream.forward(pid, "past", %{}, 500, deadline_ms: past_deadline)

      assert msg =~ "timeout"
      assert Agent.get(invocations, & &1) == 0
    end
  end

  describe "caller death, explicit cancellation, and late reply isolation" do
    test "caller death retires queued and in-flight work, releases capacity, and late replies cannot complete another request" do
      test_pid = self()
      invocations = start_supervised!({Agent, fn -> %{} end})

      call_result = fn request ->
        tool_name = get_in(request, ["params", "name"])
        Agent.update(invocations, &Map.update(&1, tool_name, 1, fn count -> count + 1 end))

        case tool_name do
          "slow_a" ->
            send(test_pid, {:slow_a_entered, self()})

            receive do
              :release_a -> tool_payload(:modern, "stale-a")
            after
              5_000 -> tool_payload(:modern, "stale-a-timeout")
            end

          "slow_b" ->
            send(test_pid, {:slow_b_entered, self()})

            receive do
              :release_b -> tool_payload(:modern, "fresh-b")
            after
              5_000 -> tool_payload(:modern, "fresh-b-timeout")
            end

          other ->
            tool_payload(:modern, "ok:#{other}")
        end
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      pid =
        start_test_upstream(
          http_config(unique_name("caller-death"), url,
            protocol_version: "2026-07-28",
            max_concurrent_calls: 1,
            max_queued_calls: 4
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      # 1. Start in-flight caller A
      caller_a = spawn(fn -> Upstream.forward(pid, "slow_a", %{}, 5_000) end)
      assert_receive {:slow_a_entered, handler_a}, 2_000

      # Record A's ToolCall reply_ref so we can inject a late reply after A is retired
      [{_req_ref_a, entry_a}] = Map.to_list(:sys.get_state(pid).in_flight)
      stale_reply_ref = entry_a.client_reply_ref

      # 2. Enqueue caller Q (will die while queued) and caller B (will take A's slot)
      caller_q = spawn(fn -> Upstream.forward(pid, "queued_dead", %{}, 5_000) end)
      assert eventually(fn -> Upstream.status(pid).queued_calls == 1 end)

      # Kill queued caller Q before A dies -> must retire Q without ever invoking upstream
      Process.exit(caller_q, :kill)
      assert eventually(fn -> Upstream.status(pid).queued_calls == 0 end)

      caller_b =
        Task.async(fn ->
          Upstream.forward(pid, "slow_b", %{}, 5_000)
        end)

      assert eventually(fn -> Upstream.status(pid).queued_calls == 1 end)

      # 3. Kill in-flight caller A -> capacity must release immediately so B enters even while handler_a is still blocked
      Process.exit(caller_a, :kill)
      assert_receive {:slow_b_entered, handler_b}, 2_000
      assert Upstream.status(pid).in_flight_calls == 1
      assert Upstream.status(pid).queued_calls == 0

      # 4. Deliver both a synthetic late ToolCall reply for A and release handler_a while B is in-flight
      stale_response = %Response{id: "stale", result: tool_payload(:modern, "hijacked-by-a")}
      send(pid, {ToolCall, stale_reply_ref, {:ok, stale_response}})
      send(handler_a, :release_a)

      # Synchronize through Upstream to verify stale reply did not complete B
      assert Upstream.status(pid).in_flight_calls == 1

      # 5. Release B and verify B receives ONLY its own result
      send(handler_b, :release_b)
      assert {:ok, b_result} = Task.await(caller_b, 2_000)
      assert [%{"text" => "fresh-b"}] = b_result["content"]
      assert eventually(fn -> Upstream.status(pid).in_flight_calls == 0 end)

      counts = Agent.get(invocations, & &1)
      assert Map.get(counts, "queued_dead", 0) == 0
      assert Map.get(counts, "slow_a", 0) == 1
      assert Map.get(counts, "slow_b", 0) == 1
    end

    test "explicit cancel_forward retires queued and in-flight calls and unblocks callers immediately" do
      test_pid = self()

      call_result = fn request ->
        case get_in(request, ["params", "name"]) do
          "blocked" ->
            send(test_pid, {:blocked_entered, self()})

            receive do
              :release -> tool_payload(:modern, "done")
            after
              5_000 -> tool_payload(:modern, "timeout")
            end

          other ->
            tool_payload(:modern, "ok:#{other}")
        end
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      pid =
        start_test_upstream(
          http_config(unique_name("explicit-cancel"), url,
            protocol_version: "2026-07-28",
            max_concurrent_calls: 1,
            max_queued_calls: 4
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)
      drain_upstream_requests()

      ref_in_flight = make_ref()
      ref_queued = make_ref()

      task_in_flight =
        Task.async(fn ->
          Upstream.forward(pid, "blocked", %{}, 5_000, request_ref: ref_in_flight)
        end)

      assert_receive {:blocked_entered, handler_pid}, 2_000

      task_queued =
        Task.async(fn ->
          Upstream.forward(pid, "queued_cancel", %{}, 5_000, request_ref: ref_queued)
        end)

      assert eventually(fn -> Upstream.status(pid).queued_calls == 1 end)

      # Cancel queued first
      assert :ok = Upstream.cancel_forward(pid, ref_queued)
      assert {:error, "Upstream call cancelled"} = Task.await(task_queued, 1_000)
      assert Upstream.status(pid).queued_calls == 0

      # Cancel in-flight next
      assert :ok = Upstream.cancel_forward(pid, ref_in_flight)
      assert {:error, "Upstream call cancelled"} = Task.await(task_in_flight, 1_000)
      assert Upstream.status(pid).in_flight_calls == 0

      # Follow-up call succeeds immediately because capacity was released
      assert {:ok, follow_up} = Upstream.forward(pid, "after_cancel", %{}, 2_000)
      assert [%{"text" => "ok:after_cancel"}] = follow_up["content"]

      send(handler_pid, :release)
    end
  end

  describe "upstream replacement and shutdown" do
    test "Pool.stop_upstream retires in-flight and queued calls cleanly and replacement serves new calls" do
      test_pid = self()
      prefix = unique_name("replace")

      call_result = fn request ->
        case get_in(request, ["params", "name"]) do
          "slow" ->
            send(test_pid, {:replace_slow_entered, self()})

            receive do
              :release -> tool_payload(:modern, "old-done")
            after
              5_000 -> tool_payload(:modern, "old-timeout")
            end

          other ->
            tool_payload(:modern, "new:#{other}")
        end
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      config =
        http_config(prefix, url,
          protocol_version: "2026-07-28",
          max_concurrent_calls: 1,
          max_queued_calls: 4
        )

      assert {:ok, old_pid} = Pool.start_upstream(config)

      assert eventually(fn ->
               Upstream.status(old_pid).status == :connected and
                 not is_nil(ToolRegistry.lookup("#{prefix}::echo"))
             end)

      in_flight_task = Task.async(fn -> Upstream.forward(old_pid, "slow", %{}, 5_000) end)
      assert_receive {:replace_slow_entered, old_handler}, 2_000

      # Queue a second call through Dispatch.call_tool to also verify enrich_upstream_meta survives stop
      queued_dispatch_task =
        Task.async(fn ->
          Dispatch.call_tool("#{prefix}::echo", %{}, %{})
        end)

      assert eventually(fn -> Upstream.status(old_pid).queued_calls == 1 end)

      # Stop the old upstream (triggers prepare_stop -> retire_all_requests)
      assert :ok = Pool.stop_upstream(old_pid)

      assert {:error, in_flight_err} = Task.await(in_flight_task, 1_000)
      assert is_binary(in_flight_err)

      assert {:error, dispatch_err} = Task.await(queued_dispatch_task, 1_000)
      assert dispatch_err =~ "failed"

      send(old_handler, :release)

      # Start replacement upstream with the same prefix
      assert {:ok, new_pid} = Pool.start_upstream(config)

      assert eventually(fn ->
               Upstream.status(new_pid).status == :connected and
                 match?({:upstream, ^new_pid, "echo", _}, ToolRegistry.resolve("#{prefix}::echo"))
             end)

      assert {:ok, result} = Dispatch.call_tool("#{prefix}::echo", %{}, %{})
      assert [%{"text" => "new:echo"}] = result["content"]
    end
  end

  describe "bounded concurrency and queue limits under contention" do
    test "enforces max_concurrent_calls and max_queued_calls without exceeding capacity" do
      test_pid = self()
      tracker = start_supervised!({Agent, fn -> %{current: 0, max_seen: 0, waiters: []} end})

      call_result = fn request ->
        id = get_in(request, ["params", "arguments", "id"])

        Agent.update(tracker, fn state ->
          current = state.current + 1

          %{
            state
            | current: current,
              max_seen: max(state.max_seen, current),
              waiters: [self() | state.waiters]
          }
        end)

        send(test_pid, {:worker_active, id, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        Agent.update(tracker, fn state -> %{state | current: state.current - 1} end)
        tool_payload(:modern, "done:#{id}")
      end

      url = start_http_fixture(mode: :modern, call_result: call_result)

      pid =
        start_test_upstream(
          http_config(unique_name("bounded"), url,
            protocol_version: "2026-07-28",
            max_concurrent_calls: 2,
            max_queued_calls: 2
          )
        )

      assert eventually(fn -> Upstream.status(pid).status == :connected end)

      # Launch 4 calls: 2 should run in-flight, 2 should wait in queue
      tasks =
        for id <- 1..4 do
          Task.async(fn ->
            {id, Upstream.forward(pid, "echo", %{"id" => id}, 5_000)}
          end)
        end

      assert_receive {:worker_active, _id1, worker1}, 2_000
      assert_receive {:worker_active, _id2, worker2}, 2_000

      assert eventually(fn ->
               status = Upstream.status(pid)
               status.in_flight_calls == 2 and status.queued_calls == 2
             end)

      # 5th call exceeds max_queued_calls -> rejected immediately with overloaded error
      assert {:error, "Upstream overloaded"} =
               Upstream.forward(pid, "echo", %{"id" => 5}, 5_000)

      # Release first 2 workers -> next 2 queued calls enter
      send(worker1, :release)
      send(worker2, :release)

      assert_receive {:worker_active, _id3, worker3}, 2_000
      assert_receive {:worker_active, _id4, worker4}, 2_000

      send(worker3, :release)
      send(worker4, :release)

      results = Enum.map(tasks, &Task.await(&1, 2_000))

      for {id, result} <- results do
        assert {:ok, %{"content" => [%{"text" => text}]}} = result
        assert text == "done:#{id}"
      end

      assert Agent.get(tracker, & &1.max_seen) == 2

      assert eventually(fn ->
               status = Upstream.status(pid)
               status.in_flight_calls == 0 and status.queued_calls == 0
             end)
    end
  end

  # Helpers

  defp tool_payload(:modern, text) do
    %{
      "resultType" => "complete",
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp tool_payload(:legacy, text) do
    %{
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp start_http_fixture(opts) do
    {:ok, bandit} =
      Gaoxy.HTTP.start_link(
        plug: {Backplane.Test.MockMcpPlug, Keyword.put(opts, :owner, self())},
        port: 0,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      if Process.alive?(bandit) do
        try do
          Gaoxy.stop(bandit)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{local: {:ok, {_ip, port}}} = Gaoxy.info(bandit, :http)
    "http://127.0.0.1:#{port}/custom/mcp"
  end

  defp start_test_upstream(config) do
    {:ok, pid} = Upstream.start_link(config)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    pid
  end

  defp http_config(label, url, overrides) do
    Map.merge(
      %{
        name: label,
        prefix: label,
        transport: "http",
        url: url,
        headers: %{},
        auth_scheme: "none"
      },
      Map.new(overrides)
    )
  end

  defp receive_upstream_request(method, timeout \\ 2_000) do
    receive do
      {:upstream_request, %{method: ^method} = request} -> request
    after
      timeout -> flunk("timed out waiting for upstream #{method} request")
    end
  end

  defp drain_upstream_requests do
    receive do
      {:upstream_request, _request} -> drain_upstream_requests()
    after
      0 -> :ok
    end
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp cleanup_upstreams do
    Pool
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: Pool.stop_upstream(pid)
    end)

    ClientPool
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_, pid, _, _} ->
      if is_pid(pid), do: DynamicSupervisor.terminate_child(ClientPool, pid)
    end)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(predicate, attempts \\ 150)

  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp write_multiplex_stdio_server(tmp_dir, started_file, gate_file) do
    path = Path.join(tmp_dir, "multiplex_stdio.sh")

    init_result =
      JSON.encode!(%{
        "protocolVersion" => "2025-11-25",
        "serverInfo" => %{"name" => "mux-stdio", "version" => "0.1.0"},
        "capabilities" => %{"tools" => %{}}
      })

    tools_result =
      JSON.encode!(%{
        "tools" => [
          %{
            "name" => "slow",
            "description" => "Slow tool",
            "inputSchema" => %{"type" => "object"}
          },
          %{
            "name" => "fast",
            "description" => "Fast tool",
            "inputSchema" => %{"type" => "object"}
          }
        ]
      })

    File.write!(path, """
    #!/bin/bash
    while IFS= read -r line; do
      method=$(printf '%s' "$line" | sed -nE 's/.*"method"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p')
      id=$(printf '%s' "$line" | sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*("[^"]*"|-?[0-9]+|null).*/\\1/p')

      case "$method" in
        initialize)
          printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" '#{init_result}'
          ;;
        notifications/*)
          ;;
        tools/list)
          printf '{"jsonrpc":"2.0","id":%s,"result":%s}\\n' "$id" '#{tools_result}'
          ;;
        ping)
          printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$id"
          ;;
        tools/call)
          tool_name=$(printf '%s' "$line" | sed -nE 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p')
          if [ "$tool_name" = "slow" ]; then
            (
              touch "#{started_file}"
              while [ ! -f "#{gate_file}" ]; do
                sleep 0.02
              done
              printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"stdio-slow"}]}}\\n' "$id"
            ) &
          else
            printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"stdio-fast"}]}}\\n' "$id"
          fi
          ;;
      esac
    done
    wait
    """)

    path
  end
end
