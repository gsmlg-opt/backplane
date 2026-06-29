defmodule Backplane.Settings.OAuthStateStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.Settings.OAuthStateStore

  setup do
    if function_exported?(OAuthStateStore, :clear, 0) do
      OAuthStateStore.clear()
    end

    :ok
  end

  test "pop consumes state only once" do
    state = OAuthStateStore.put(%{"purpose" => "test"})

    assert {:ok, %{"purpose" => "test"}} = OAuthStateStore.pop(state)
    assert :error = OAuthStateStore.pop(state)
  end

  test "clear removes stored states" do
    state = OAuthStateStore.put(%{"purpose" => "test"})

    OAuthStateStore.clear()

    assert :error = OAuthStateStore.pop(state)
  end

  test "state table is protected from direct writes outside the owner process" do
    _state = OAuthStateStore.put(%{"purpose" => "test"})

    assert :protected = :ets.info(:oauth_state_store, :protection)

    assert_raise ArgumentError, fn ->
      :ets.insert(:oauth_state_store, {"forged", %{"purpose" => "test"}, 0})
    end
  end
end
