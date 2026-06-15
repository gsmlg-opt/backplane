defmodule Backplane.McpProtocol.SessionStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.SessionStore

  setup do
    start_supervised!(SessionStore)
    :ok
  end

  test "creates, fetches, touches, and deletes sessions" do
    assert {:ok, id} = SessionStore.create(%{protocol_version: "2025-11-25"})

    assert %{protocol_version: "2025-11-25", created_at: created_at, last_seen_at: last_seen_at} =
             SessionStore.get(id)

    assert is_integer(created_at)
    assert is_integer(last_seen_at)

    assert :ok = SessionStore.touch(id)
    assert %{protocol_version: "2025-11-25"} = SessionStore.get(id)

    assert :ok = SessionStore.delete(id)
    assert SessionStore.get(id) == nil
  end

  test "cleanup_stale removes sessions older than max age" do
    assert {:ok, id} = SessionStore.create(%{protocol_version: "2025-11-25"})

    old =
      SessionStore.get(id)
      |> Map.put(:last_seen_at, System.system_time(:second) - 10)

    :ets.insert(:backplane_mcp_protocol_sessions, {id, old})

    assert SessionStore.cleanup_stale(1) == 1
    assert SessionStore.get(id) == nil
  end
end
