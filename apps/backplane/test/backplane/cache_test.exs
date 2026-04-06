defmodule Backplane.CacheTest do
  use ExUnit.Case, async: false

  alias Backplane.Cache

  setup do
    Cache.flush()
    :ok
  end

  describe "get/put" do
    test "returns :miss for unknown key" do
      assert Cache.get(:nonexistent) == :miss
    end

    test "returns {:ok, value} for cached key" do
      Cache.put(:hello, "world", 5_000)
      Process.sleep(10)

      assert Cache.get(:hello) == {:ok, "world"}
    end

    test "returns :miss after TTL expiration" do
      Cache.put(:ephemeral, "gone_soon", 50)
      Process.sleep(10)

      assert Cache.get(:ephemeral) == {:ok, "gone_soon"}

      Process.sleep(100)

      assert Cache.get(:ephemeral) == :miss
    end

    test "overwrites existing key" do
      Cache.put(:key, "first", 5_000)
      Process.sleep(10)
      assert Cache.get(:key) == {:ok, "first"}

      Cache.put(:key, "second", 5_000)
      Process.sleep(10)
      assert Cache.get(:key) == {:ok, "second"}
    end

    test "put after max_entries does not crash" do
      # We cannot easily control max_entries on the running GenServer,
      # so we verify that inserting many entries does not raise.
      for i <- 1..100 do
        Cache.put({:overflow, i}, i, 5_000)
      end

      Process.sleep(50)

      # At least one entry should be retrievable
      assert {:ok, _} = Cache.get({:overflow, 100})
    end
  end

  describe "invalidate" do
    test "removes specific key" do
      Cache.put(:to_remove, "value", 5_000)
      Process.sleep(10)
      assert Cache.get(:to_remove) == {:ok, "value"}

      Cache.invalidate(:to_remove)
      Process.sleep(10)
      assert Cache.get(:to_remove) == :miss
    end

    test "returns :ok for non-existent key" do
      assert Cache.invalidate(:does_not_exist) == :ok
    end
  end

  describe "invalidate_prefix" do
    test "removes all keys matching prefix" do
      Cache.put({:git, "github", "owner", "repo", "fetch_tree", nil}, "tree_data", 5_000)
      Cache.put({:git, "github", "owner", "repo", "fetch_file", "README.md"}, "file_data", 5_000)
      Cache.put({:git, "github", "owner", "repo", "list_branches", nil}, "branches", 5_000)
      Process.sleep(10)

      count = Cache.invalidate_prefix({:git, "github", "owner", "repo"})
      assert count == 3

      assert Cache.get({:git, "github", "owner", "repo", "fetch_tree", nil}) == :miss
      assert Cache.get({:git, "github", "owner", "repo", "fetch_file", "README.md"}) == :miss
      assert Cache.get({:git, "github", "owner", "repo", "list_branches", nil}) == :miss
    end

    test "returns count of evicted entries" do
      Cache.put({:docs, "project_a", "search"}, "results_a", 5_000)
      Cache.put({:docs, "project_a", "list"}, "results_b", 5_000)
      Process.sleep(10)

      count = Cache.invalidate_prefix({:docs, "project_a"})
      assert count == 2
    end

    test "does not affect keys with different prefix" do
      Cache.put({:git, "github", "owner", "repo_a", "tree"}, "a", 5_000)
      Cache.put({:git, "github", "owner", "repo_b", "tree"}, "b", 5_000)
      Cache.put({:git, "gitlab", "owner", "repo_a", "tree"}, "c", 5_000)
      Process.sleep(10)

      Cache.invalidate_prefix({:git, "github", "owner", "repo_a"})

      assert Cache.get({:git, "github", "owner", "repo_a", "tree"}) == :miss
      assert Cache.get({:git, "github", "owner", "repo_b", "tree"}) == {:ok, "b"}
      assert Cache.get({:git, "gitlab", "owner", "repo_a", "tree"}) == {:ok, "c"}
    end
  end

  describe "stats" do
    test "increments hits on cache hit" do
      initial = Cache.stats()

      Cache.put(:stat_hit, "value", 5_000)
      Process.sleep(10)
      Cache.get(:stat_hit)

      updated = Cache.stats()
      assert updated.hits == initial.hits + 1
    end

    test "increments misses on cache miss" do
      initial = Cache.stats()

      Cache.get(:stat_miss_key)

      updated = Cache.stats()
      assert updated.misses == initial.misses + 1
    end

    test "reports correct size" do
      assert Cache.stats().size == 0

      Cache.put(:size_a, "a", 5_000)
      Cache.put(:size_b, "b", 5_000)
      Cache.put(:size_c, "c", 5_000)
      Process.sleep(10)

      assert Cache.stats().size == 3
    end
  end
end
