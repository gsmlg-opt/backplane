defmodule Backplane.HostAgent.Memory.RecallCacheTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Memory.RecallCache

  test "bounds entries and bytes, expires entries, and isolates lifecycle kinds" do
    cache =
      start_supervised!(
        {RecallCache, name: nil, max_entries: 2, max_bytes: 700, ttl_ms: 30, id: make_ref()}
      )

    session_key = {"session_start", "/work", "agent", "session"}
    compact_key = {"pre_compact", "/work", "agent", "session"}

    assert :ok = RecallCache.put(cache, session_key, context("one"))
    assert {:ok, %{context: %{"context" => "one"}}} = RecallCache.get(cache, session_key)
    assert :miss = RecallCache.get(cache, compact_key)

    assert :ok = RecallCache.put(cache, compact_key, context("two"))

    assert :ok =
             RecallCache.put(
               cache,
               {"session_start", "/other", "agent", "session"},
               context("three")
             )

    assert :miss = RecallCache.get(cache, session_key)
    assert %{entries: 2, bytes: bytes} = RecallCache.stats(cache)
    assert bytes <= 700

    Process.sleep(35)
    assert :miss = RecallCache.get(cache, compact_key)
  end

  test "rejects a single entry larger than the byte budget" do
    cache =
      start_supervised!({RecallCache, name: nil, max_entries: 2, max_bytes: 8, id: make_ref()})

    assert :ok = RecallCache.put(cache, :large, context(String.duplicate("x", 100)))
    assert :miss = RecallCache.get(cache, :large)
    assert %{entries: 0, bytes: 0} = RecallCache.stats(cache)
  end

  test "accounts caller-derived key bytes and rejects an oversized key" do
    cache =
      start_supervised!({RecallCache, name: nil, max_entries: 2, max_bytes: 400, id: make_ref()})

    oversized_key = {"session_start", String.duplicate("p", 1_000), "agent"}
    assert :ok = RecallCache.put(cache, oversized_key, context("small"))
    assert :miss = RecallCache.get(cache, oversized_key)
    assert %{entries: 0, bytes: 0} = RecallCache.stats(cache)
  end

  test "replacement, rejection, and eviction keep retained byte totals exact and nonnegative" do
    first_key = {"session_start", "/first", "agent"}
    second_key = {"session_start", "/second", "agent"}
    first_context = context("one")
    replacement_context = context("two")
    second_context = context("three")

    cache =
      start_supervised!(
        {RecallCache, name: nil, max_entries: 1, max_bytes: 10_000, id: make_ref()}
      )

    assert :ok = RecallCache.put(cache, first_key, first_context)
    assert %{entries: 1, bytes: first_bytes} = RecallCache.stats(cache)
    assert first_bytes == accounted_bytes(first_key, first_context)
    assert first_bytes > byte_size(:erlang.term_to_binary(first_context))

    assert :ok = RecallCache.put(cache, first_key, replacement_context)
    assert %{entries: 1, bytes: replacement_bytes} = RecallCache.stats(cache)
    assert replacement_bytes == accounted_bytes(first_key, replacement_context)

    measurement_cache =
      start_supervised!(
        {RecallCache, name: nil, max_entries: 1, max_bytes: 10_000, id: make_ref()}
      )

    assert :ok = RecallCache.put(measurement_cache, second_key, second_context)
    assert %{entries: 1, bytes: second_bytes} = RecallCache.stats(measurement_cache)
    assert second_bytes == accounted_bytes(second_key, second_context)

    assert :ok = RecallCache.put(cache, second_key, second_context)
    assert :miss = RecallCache.get(cache, first_key)
    assert %{entries: 1, bytes: ^second_bytes} = RecallCache.stats(cache)

    oversized_context = context(String.duplicate("x", 20_000))
    assert :ok = RecallCache.put(cache, second_key, oversized_context)
    assert %{entries: 0, bytes: 0} = RecallCache.stats(cache)
    assert replacement_bytes >= 0
  end

  defp accounted_bytes(key, context) do
    byte_size(:erlang.term_to_binary({key, context})) + 64
  end

  defp context(text) do
    now = DateTime.utc_now()

    %{
      "context" => text,
      "source_revision" => "sha256:revision",
      "generated_at" => DateTime.to_iso8601(now),
      "expires_at" => now |> DateTime.add(900, :second) |> DateTime.to_iso8601()
    }
  end
end
