defmodule Backplane.Settings.TokenCacheTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.TokenCache

  setup do
    TokenCache.clear()
    :ok
  end

  describe "get/1" do
    test "returns :miss for unknown key" do
      assert :miss = TokenCache.get("unknown")
    end

    test "returns {:ok, token} for cached valid entry" do
      TokenCache.put("test-cred", "tok-123", 3600)
      assert {:ok, "tok-123"} = TokenCache.get("test-cred")
    end

    test "returns :miss for expired entry" do
      TokenCache.put("expired", "tok", 0)
      assert :miss = TokenCache.get("expired")
    end
  end

  describe "put/3" do
    test "stores token with calculated expires_at" do
      TokenCache.put("k", "v", 3600)
      assert {:ok, "v"} = TokenCache.get("k")
    end

    test "overwrites existing entry" do
      TokenCache.put("k", "old", 3600)
      TokenCache.put("k", "new", 3600)
      assert {:ok, "new"} = TokenCache.get("k")
    end
  end

  describe "invalidate/1" do
    test "removes cached entry" do
      TokenCache.put("k", "v", 3600)
      TokenCache.invalidate("k")
      assert :miss = TokenCache.get("k")
    end

    test "no-op for unknown key" do
      assert :ok = TokenCache.invalidate("ghost")
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      TokenCache.put("a", "1", 3600)
      TokenCache.put("b", "2", 3600)
      TokenCache.clear()
      assert :miss = TokenCache.get("a")
      assert :miss = TokenCache.get("b")
    end
  end
end
