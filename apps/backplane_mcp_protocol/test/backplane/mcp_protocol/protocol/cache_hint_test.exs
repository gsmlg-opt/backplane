defmodule Backplane.McpProtocol.Protocol.CacheHintTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Protocol.CacheHint

  test "defaults to an immediately stale private response" do
    assert %CacheHint{ttl_ms: 0, scope: :private} = CacheHint.default()
    assert {:ok, %CacheHint{ttl_ms: 0, scope: :private}} = CacheHint.new(%{})

    assert %{"ttlMs" => 0, "cacheScope" => "private"} =
             CacheHint.put(%{}, CacheHint.default())
  end

  test "parses and emits valid wire hints without changing other fields" do
    result = %{"resultType" => "complete", "ttlMs" => 30_000, "cacheScope" => "public"}

    assert {:ok, %CacheHint{ttl_ms: 30_000, scope: :public}} = CacheHint.parse(result)
    assert CacheHint.put(%{"resultType" => "complete"}, %CacheHint{ttl_ms: 30_000, scope: :public}) == result
  end

  test "rejects invalid TTLs and scopes" do
    assert {:error, {:invalid_ttl_ms, -1}} = CacheHint.new(%{"ttlMs" => -1})
    assert {:error, {:invalid_ttl_ms, 1.5}} = CacheHint.new(%{"ttlMs" => 1.5})
    assert {:error, {:invalid_cache_scope, "shared"}} = CacheHint.new(%{"cacheScope" => "shared"})
  end

  test "recognizes exactly the frozen core cacheable methods" do
    expected = ~w(
      server/discover tools/list prompts/list resources/list
      resources/templates/list resources/read
    )

    assert Enum.all?(expected, &CacheHint.cacheable_method?/1)

    refute CacheHint.cacheable_method?("tools/call")
    refute CacheHint.cacheable_method?("prompts/get")
    refute CacheHint.cacheable_method?("tasks/get")
    refute CacheHint.cacheable_method?(:"tools/list")
  end
end
