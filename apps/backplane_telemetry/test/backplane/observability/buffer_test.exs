defmodule Backplane.Observability.BufferTest do
  use ExUnit.Case, async: false

  alias Backplane.Observability.Buffer

  setup do
    start_supervised!({Buffer, [name: :buffer_test, capacity: 2]})
    on_exit(fn -> Buffer.release(:buffer_test, 10) end)
    :ok
  end

  test "accepts events up to capacity and rejects overflow" do
    assert :ok = Buffer.try_enqueue(:buffer_test, %{id: 1})
    assert :ok = Buffer.try_enqueue(:buffer_test, %{id: 2})
    assert {:error, :full} = Buffer.try_enqueue(:buffer_test, %{id: 3})
  end

  test "drains and releases reserved capacity" do
    :ok = Buffer.try_enqueue(:buffer_test, %{id: 1})
    assert [%{id: 1}] = Buffer.drain(:buffer_test, 10)
    :ok = Buffer.release(:buffer_test, 1)

    health = Buffer.health(:buffer_test)
    assert health.reserved == 0
    assert health.queued == 0
  end
end
