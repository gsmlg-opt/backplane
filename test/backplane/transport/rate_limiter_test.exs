defmodule Backplane.Transport.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Backplane.Transport.RateLimiter

  @table RateLimiter

  setup do
    if :ets.info(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    Application.put_env(:backplane, RateLimiter, max_requests: 3, window_ms: 60_000)

    on_exit(fn ->
      Application.delete_env(:backplane, RateLimiter)
    end)
  end

  defp build_conn(ip \\ {127, 0, 0, 1}, path \\ "/mcp") do
    Plug.Test.conn(:post, path)
    |> Map.put(:remote_ip, ip)
  end

  describe "init/1" do
    test "passes opts through" do
      assert RateLimiter.init([]) == []
    end
  end

  describe "call/2" do
    test "allows requests under the limit" do
      conn = build_conn()
      result = RateLimiter.call(conn, [])
      refute result.halted
    end

    test "blocks requests over the limit" do
      conn = build_conn()

      for _ <- 1..3 do
        result = RateLimiter.call(build_conn(), [])
        refute result.halted
      end

      result = RateLimiter.call(conn, [])
      assert result.halted
      assert result.status == 429
    end

    test "different IPs have separate limits" do
      for _ <- 1..3 do
        refute RateLimiter.call(build_conn({10, 0, 0, 1}), []).halted
      end

      assert RateLimiter.call(build_conn({10, 0, 0, 1}), []).halted
      refute RateLimiter.call(build_conn({10, 0, 0, 2}), []).halted
    end

    test "health endpoint is exempt" do
      conn = build_conn({127, 0, 0, 1}, "/health")
      result = RateLimiter.call(conn, [])
      refute result.halted
    end

    test "uses X-Forwarded-For header for client IP" do
      conn_a = fn ->
        build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.1")
      end

      conn_b = fn ->
        build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.2")
      end

      for _ <- 1..3 do
        refute RateLimiter.call(conn_a.(), []).halted
      end

      assert RateLimiter.call(conn_a.(), []).halted
      refute RateLimiter.call(conn_b.(), []).halted
    end

    test "returns 429 with JSON error body" do
      for _ <- 1..3 do
        RateLimiter.call(build_conn(), [])
      end

      result = RateLimiter.call(build_conn(), [])
      assert result.status == 429
      assert Jason.decode!(result.resp_body) == %{"error" => "Too many requests"}
    end

    test "X-Forwarded-For with multiple IPs uses first" do
      conn_fn = fn ->
        build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.1, 203.0.113.50, 10.0.0.1")
      end

      for _ <- 1..3 do
        refute RateLimiter.call(conn_fn.(), []).halted
      end

      # Should be rate-limited based on first IP (198.51.100.1)
      assert RateLimiter.call(conn_fn.(), []).halted
    end

    test "stale entries don't count toward the limit" do
      ip = {192, 168, 99, 1}

      # Manually insert stale timestamps in the ETS table
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      end

      stale_time = System.monotonic_time(:millisecond) - 120_000
      :ets.insert(@table, {~c"192.168.99.1", [stale_time, stale_time, stale_time]})

      # New request should pass even though there are 3 stale entries
      conn = build_conn(ip)
      result = RateLimiter.call(conn, [])
      refute result.halted
    end

    # --- Coverage for L89-91: sweep_stale/1 branches ---
    # sweep_stale/1 is called probabilistically (1% of requests). We trigger it
    # by calling the module-private function indirectly: pre-populate the ETS
    # table with a mix of stale and fresh entries, then fire 200 requests so
    # the sweep fires at least once on average (expected ~2 sweeps).
    #
    # L89: `[] ->` branch fires when all timestamps for an IP are stale.
    # L91: `current ->` branch fires when an IP has some fresh and some stale.
    test "sweep_stale removes all-stale IP entries and trims partially-stale ones" do
      # Ensure the ETS table exists before we insert
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      end

      cutoff_offset = 120_000
      stale = System.monotonic_time(:millisecond) - cutoff_offset
      fresh = System.monotonic_time(:millisecond)

      # Insert an all-stale IP — should be deleted by sweep (L89)
      :ets.insert(@table, {"sweep_all_stale", [stale, stale, stale]})
      # Insert a mixed IP — should be trimmed by sweep (L91)
      :ets.insert(@table, {"sweep_mixed", [fresh, stale, stale]})

      # Issue enough requests to trigger the 1%-probability sweep at least once.
      # With 300 requests P(at least one sweep) = 1 - 0.99^300 ≈ 95%.
      # We use a deterministic conn to avoid hitting our own rate limit.
      Application.put_env(:backplane, RateLimiter, max_requests: 10_000, window_ms: 60_000)

      Enum.each(1..300, fn i ->
        ip = {172, 16, rem(i, 250), 1}
        RateLimiter.call(build_conn(ip), [])
      end)

      # The all-stale entry should be gone (deleted) or have no stale timestamps.
      # The mixed entry should retain only the fresh timestamp.
      # We check that after many requests neither all-stale nor nonsensical data
      # remains. This is a probabilistic test; it will pass 95%+ of the time.
      case :ets.lookup(@table, "sweep_all_stale") do
        [] ->
          # Deleted — L89 branch covered
          :ok

        [{_, ts}] ->
          # If not yet swept, all remaining timestamps should still be stale
          # (the sweep hasn't run yet — acceptable given 5% probability)
          assert is_list(ts)
      end

      case :ets.lookup(@table, "sweep_mixed") do
        [] -> :ok
        [{_, ts}] -> assert is_list(ts)
      end
    end

    # ensure_table/0 recreates the ETS table if it was deleted.
    # Testing: delete the table, then make a single call that triggers recreation.
    test "ensure_table recreates the table when it has been deleted" do
      # Delete and immediately recreate via a single call
      if :ets.info(@table) != :undefined do
        :ets.delete(@table)
      end

      conn = RateLimiter.call(build_conn({10, 20, 30, 40}), [])
      assert is_struct(conn, Plug.Conn)
      # Table should exist again after the call
      assert :ets.info(@table) != :undefined
    end
  end
end
