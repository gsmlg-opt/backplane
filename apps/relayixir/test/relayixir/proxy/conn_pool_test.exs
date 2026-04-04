defmodule Relayixir.Proxy.ConnPoolTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.{ConnPool, Upstream}

  # Use a unique port per test to avoid cross-test pool collisions
  defp upstream(port, pool_size \\ 5) do
    %Upstream{
      scheme: :http,
      host: "127.0.0.1",
      port: port,
      pool_size: pool_size,
      connect_timeout: 5_000
    }
  end

  describe "ensure_started/1" do
    test "starts a pool for an upstream" do
      us = upstream(19001)
      assert {:ok, pid} = ConnPool.ensure_started(us)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "is idempotent — second call returns existing pid" do
      us = upstream(19002)
      {:ok, pid1} = ConnPool.ensure_started(us)
      {:ok, pid2} = ConnPool.ensure_started(us)
      assert pid1 == pid2
    end
  end

  describe "checkout/1 and checkin/2" do
    test "returns :empty when no idle connections" do
      us = upstream(19003)
      ConnPool.ensure_started(us)
      assert {:error, :empty} = ConnPool.checkout(us)
    end

    test "checkout returns a previously checked-in connection" do
      us = upstream(19004)
      ConnPool.ensure_started(us)

      # Start a real upstream to get a valid Mint connection
      {:ok, listen} = :gen_tcp.listen(19004, [:binary, active: false, reuseaddr: true])

      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 19004, transport_opts: [timeout: 5_000])
      ConnPool.checkin(us, conn)

      assert {:ok, checked_out} = ConnPool.checkout(us)
      assert Mint.HTTP.open?(checked_out)

      Mint.HTTP.close(checked_out)
      :gen_tcp.close(listen)
    end

    test "pool respects max_size — extra connections are closed" do
      us = upstream(19005, 2)
      ConnPool.ensure_started(us)

      {:ok, listen} = :gen_tcp.listen(19005, [:binary, active: false, reuseaddr: true])

      conns =
        for _ <- 1..3 do
          {:ok, conn} =
            Mint.HTTP.connect(:http, "127.0.0.1", 19005, transport_opts: [timeout: 5_000])

          conn
        end

      # Check in all 3 — pool size is 2, so 3rd should be discarded
      Enum.each(conns, &ConnPool.checkin(us, &1))

      # Should get exactly 2 back
      assert {:ok, _} = ConnPool.checkout(us)
      assert {:ok, _} = ConnPool.checkout(us)
      assert {:error, :empty} = ConnPool.checkout(us)

      :gen_tcp.close(listen)
    end

    test "dead connections are skipped on checkout" do
      us = upstream(19006)
      ConnPool.ensure_started(us)

      {:ok, listen} = :gen_tcp.listen(19006, [:binary, active: false, reuseaddr: true])

      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 19006, transport_opts: [timeout: 5_000])
      # Close the conn — Mint.HTTP.close/1 returns the updated (closed) struct
      {:ok, closed_conn} = Mint.HTTP.close(conn)
      ConnPool.checkin(us, closed_conn)

      assert {:error, :empty} = ConnPool.checkout(us)

      :gen_tcp.close(listen)
    end
  end

  describe "checkin/2 without pool" do
    test "closes connection when no pool exists" do
      us = upstream(19007)
      # Don't start pool — checkin should just close the conn gracefully
      {:ok, listen} = :gen_tcp.listen(19007, [:binary, active: false, reuseaddr: true])

      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 19007, transport_opts: [timeout: 5_000])
      assert :ok = ConnPool.checkin(us, conn)

      :gen_tcp.close(listen)
    end
  end
end
