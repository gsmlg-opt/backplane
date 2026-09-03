defmodule Backplane.Admin.LogsComponentsTest do
  use ExUnit.Case, async: true

  import Backplane.Admin.LogsComponents

  test "parse_llm_filters applies default bounded time range" do
    filters = parse_llm_filters(%{"model" => "gpt-test"})

    assert filters.model == "gpt-test"
    assert %DateTime{} = filters.since
    assert %DateTime{} = filters.until
    assert DateTime.compare(filters.since, filters.until) == :lt
  end

  test "parse_cursor decodes keyset cursor" do
    dt = ~U[2026-01-01 12:00:00Z]
    id = Ecto.UUID.generate()

    assert parse_cursor("#{DateTime.to_iso8601(dt)}|#{id}") == {dt, id}
    assert parse_cursor("invalid") == nil
  end

  test "encode_cursor round-trips inserted_at and id" do
    dt = ~U[2026-01-01 12:00:00Z]
    id = Ecto.UUID.generate()
    cursor = encode_cursor(%{inserted_at: dt, id: id})

    assert parse_cursor(cursor) == {dt, id}
  end

  test "metadata_summary redacts and bounds metadata" do
    summary =
      metadata_summary(%{
        "token" => "secret-value",
        "messages" => [%{"role" => "user"}],
        "safe" => "ok"
      })

    assert summary =~ "safe"
    refute summary =~ "secret-value"
    assert summary =~ "[REDACTED]"
  end

  test "bounded_error truncates long error text" do
    long = String.duplicate("x", 5000)
    bounded = bounded_error(long)
    assert String.length(bounded) <= 1024
  end

  test "payload_status reports bytes-only when byte counts exist" do
    assert payload_status(%{request_bytes: 100, response_bytes: 0}) == "bytes only"
    assert payload_status(%{}) == "none"
  end
end
