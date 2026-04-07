defmodule Backplane.LLM.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Backplane.LLM.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  describe "check/2" do
    test "allows requests under the limit" do
      assert :ok = RateLimiter.check("provider-a", 10)
      assert :ok = RateLimiter.check("provider-a", 10)
      assert :ok = RateLimiter.check("provider-a", 10)
    end

    test "rejects requests over the limit and returns retry_after" do
      limit = 3

      for _ <- 1..limit do
        assert :ok = RateLimiter.check("provider-b", limit)
      end

      assert {:error, retry_after} = RateLimiter.check("provider-b", limit)
      assert is_integer(retry_after)
      assert retry_after >= 1
      assert retry_after <= 60
    end

    test "resets after window expires" do
      limit = 2

      for _ <- 1..limit do
        assert :ok = RateLimiter.check("provider-c", limit)
      end

      assert {:error, _} = RateLimiter.check("provider-c", limit)

      # Expire the window and try again
      RateLimiter.expire("provider-c")

      assert :ok = RateLimiter.check("provider-c", limit)
    end

    test "skips rate limiting when limit is nil" do
      for _ <- 1..1000 do
        assert :ok = RateLimiter.check("provider-d", nil)
      end
    end

    test "handles concurrent requests without crashing" do
      limit = 100
      provider = "provider-concurrent-#{System.unique_integer([:positive])}"

      tasks =
        for _ <- 1..50 do
          Task.async(fn -> RateLimiter.check(provider, limit) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, fn r -> r == :ok or match?({:error, _}, r) end)
    end
  end
end
