defmodule FakeProvider do
end

defmodule Backplane.Git.CachedProviderTest do
  use ExUnit.Case, async: false

  alias Backplane.Git.CachedProvider
  alias Backplane.Cache

  setup do
    Cache.flush()
    :ok
  end

  describe "fetch_tree (cached)" do
    test "calls function on first request (cache miss)" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, [%{path: "lib/", type: "tree"}]}
      end

      result =
        CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, fun)

      assert {:ok, _} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "returns cached result on second request (cache hit, function NOT called again)" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, [%{path: "lib/", type: "tree"}]}
      end

      result =
        CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, fun)

      assert {:ok, _} = result
      assert :counters.get(call_count, 1) == 1

      # Allow the async Cache.put cast to complete
      Process.sleep(10)

      result2 =
        CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, fun)

      assert result2 == result
      assert :counters.get(call_count, 1) == 1
    end

    test "calls function again after TTL expiry" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, [%{path: "src/", type: "tree"}]}
      end

      # Manually insert a cache entry with a very short TTL (1ms)
      provider = CachedProvider.provider_name(FakeProvider)

      key =
        Backplane.Cache.KeyBuilder.git(provider, "owner", "repo", "fetch_tree", %{ref: "main"})

      Cache.put(key, {:ok, [%{path: "src/", type: "tree"}]}, 1)
      Process.sleep(10)

      # Entry should have expired; CachedProvider should call the function
      result =
        CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, fun)

      assert {:ok, _} = result
      assert :counters.get(call_count, 1) == 1
    end

    test "cache invalidated by invalidate_repo triggers function call" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, [%{path: "lib/", type: "tree"}]}
      end

      # Populate cache
      CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, fun)
      assert :counters.get(call_count, 1) == 1
      Process.sleep(10)

      # Invalidate all cache entries for this repo
      CachedProvider.invalidate_repo("fakeprovider", "owner", "repo")

      # Next call should be a cache miss
      result =
        CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, fun)

      assert {:ok, _} = result
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "fetch_file (cached)" do
    test "caches file content" do
      call_count = :counters.new(1, [:atomics])

      fun = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, "defmodule Foo do\nend\n"}
      end

      result =
        CachedProvider.cached(
          FakeProvider,
          "fetch_file",
          "owner/repo",
          %{ref: "main", path: "lib/foo.ex"},
          fun
        )

      assert {:ok, "defmodule Foo do\nend\n"} = result
      assert :counters.get(call_count, 1) == 1

      Process.sleep(10)

      result2 =
        CachedProvider.cached(
          FakeProvider,
          "fetch_file",
          "owner/repo",
          %{ref: "main", path: "lib/foo.ex"},
          fun
        )

      assert result2 == result
      assert :counters.get(call_count, 1) == 1
    end

    test "respects per-endpoint TTL (fetch_file and fetch_tree both cache correctly)" do
      tree_count = :counters.new(1, [:atomics])
      file_count = :counters.new(1, [:atomics])

      tree_fun = fn ->
        :counters.add(tree_count, 1, 1)
        {:ok, [%{path: "lib/", type: "tree"}]}
      end

      file_fun = fn ->
        :counters.add(file_count, 1, 1)
        {:ok, "file content"}
      end

      # Populate both caches
      CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, tree_fun)

      CachedProvider.cached(
        FakeProvider,
        "fetch_file",
        "owner/repo",
        %{ref: "main", path: "README.md"},
        file_fun
      )

      assert :counters.get(tree_count, 1) == 1
      assert :counters.get(file_count, 1) == 1

      Process.sleep(10)

      # Both should return cached results
      CachedProvider.cached(FakeProvider, "fetch_tree", "owner/repo", %{ref: "main"}, tree_fun)

      CachedProvider.cached(
        FakeProvider,
        "fetch_file",
        "owner/repo",
        %{ref: "main", path: "README.md"},
        file_fun
      )

      assert :counters.get(tree_count, 1) == 1
      assert :counters.get(file_count, 1) == 1
    end
  end
end
