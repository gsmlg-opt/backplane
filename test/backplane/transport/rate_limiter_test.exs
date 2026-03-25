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
  end
end
