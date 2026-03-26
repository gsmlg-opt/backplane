defmodule Backplane.Git.RateLimitCacheTest do
  use ExUnit.Case, async: true

  alias Backplane.Git.RateLimitCache

  setup do
    RateLimitCache.init()
    :ok
  end

  describe "put/2 and get/1" do
    test "stores and retrieves rate limit info" do
      RateLimitCache.put("github", %{remaining: 4999, limit: 5000, reset: 1_700_000_000})
      info = RateLimitCache.get("github")

      assert info.remaining == 4999
      assert info.limit == 5000
      assert info.reset == 1_700_000_000
    end

    test "returns nil for unknown provider" do
      assert RateLimitCache.get("unknown-provider") == nil
    end

    test "overwrites previous entry" do
      RateLimitCache.put("github", %{remaining: 5000, limit: 5000, reset: 100})
      RateLimitCache.put("github", %{remaining: 4000, limit: 5000, reset: 200})

      info = RateLimitCache.get("github")
      assert info.remaining == 4000
      assert info.reset == 200
    end

    test "handles multiple providers independently" do
      RateLimitCache.put("github", %{remaining: 4999, limit: 5000, reset: 100})
      RateLimitCache.put("gitlab", %{remaining: 999, limit: 1000, reset: 200})

      gh = RateLimitCache.get("github")
      gl = RateLimitCache.get("gitlab")

      assert gh.remaining == 4999
      assert gl.remaining == 999
    end
  end

  describe "all/0" do
    test "returns all stored entries" do
      RateLimitCache.put("github", %{remaining: 100, limit: 5000, reset: 100})
      RateLimitCache.put("gitlab", %{remaining: 50, limit: 1000, reset: 200})

      entries = RateLimitCache.all()
      keys = Enum.map(entries, &elem(&1, 0))

      assert "github" in keys
      assert "gitlab" in keys
    end
  end
end
