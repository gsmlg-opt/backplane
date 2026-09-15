defmodule Backplane.Memory.SlotsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Slots
  alias Backplane.Memory.Slots.Reflect
  alias Backplane.Memory.Slots.Slot

  setup do
    %{
      partition:
        canonical_partition("slots-test-owner",
          client_id: "slots-test-client",
          scope: "slots-test"
        )
    }
  end

  describe "write/4" do
    test "stores content in a new slot", %{partition: partition} do
      assert {:ok, slot} =
               Slots.write("self_notes", "remember to hydrate", "test_actor", partition)

      assert slot.name == "self_notes"
      assert slot.content == "remember to hydrate"
      assert slot.updated_by == "test_actor"
    end

    test "creates a new slot if name does not exist yet", %{partition: partition} do
      name = "custom_slot_#{System.unique_integer([:positive])}"
      assert {:ok, slot} = Slots.write(name, "some content", nil, partition)
      assert slot.name == name
      assert slot.content == "some content"
    end

    test "overwrites existing slot content", %{partition: partition} do
      name = "guidance"
      {:ok, _} = Slots.write(name, "first content", nil, partition)
      assert {:ok, slot} = Slots.write(name, "second content", "updater", partition)
      assert slot.content == "second content"
      assert slot.updated_by == "updater"
    end

    test "fails when content exceeds size_limit_chars", %{partition: partition} do
      # Default size_limit_chars is 2000; write a slot with a tiny limit first
      repo = repo()
      name = "tiny_slot_#{System.unique_integer([:positive])}"

      repo.insert!(
        struct(
          Slot,
          Map.merge(partition, %{
            name: name,
            content: "",
            updated_at: DateTime.utc_now(),
            size_limit_chars: 10
          })
        )
      )

      assert {:error, changeset} =
               Slots.write(name, String.duplicate("x", 11), nil, partition)

      assert errors_on(changeset)[:content] != nil
    end
  end

  describe "read/2" do
    test "returns the slot for a known name", %{partition: partition} do
      {:ok, _} = Slots.write("persona", "I am a helpful assistant", nil, partition)
      assert {:ok, slot} = Slots.read("persona", partition)
      assert slot.content == "I am a helpful assistant"
    end

    test "returns {:error, :not_found} for an unknown slot", %{partition: partition} do
      assert {:error, :not_found} = Slots.read("nonexistent_slot_xyz", partition)
    end
  end

  describe "list/1" do
    test "returns all slots ordered by name", %{partition: partition} do
      for name <- ~w(guidance pending_items session_patterns self_notes) do
        assert {:ok, _slot} = Slots.write(name, "", nil, partition)
      end

      slots = Slots.list(partition)
      assert is_list(slots)
      names = Enum.map(slots, & &1.name)
      assert "guidance" in names
      assert "pending_items" in names
      assert "session_patterns" in names
      assert "self_notes" in names
    end

    test "results are ordered by name ascending", %{partition: partition} do
      for name <- ~w(zeta alpha middle) do
        assert {:ok, _slot} = Slots.write(name, "", nil, partition)
      end

      slots = Slots.list(partition)
      names = Enum.map(slots, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "reflection" do
    test "partitionless reflection fails closed without writing slots" do
      key = "memory.reflect_enabled"
      previous = :ets.lookup(:backplane_settings, key)

      on_exit(fn ->
        :ets.delete(:backplane_settings, key)
        if previous != [], do: :ets.insert(:backplane_settings, previous)
      end)

      initial_count = repo().aggregate(Slot, :count)

      :ets.insert(:backplane_settings, {key, "true"})
      assert {:skip, :incomplete_partition} = Reflect.run("session-without-partition")
      assert repo().aggregate(Slot, :count) == initial_count

      :ets.insert(:backplane_settings, {key, "false"})
      assert {:skip, :disabled} = Reflect.run("session-without-partition")
      assert repo().aggregate(Slot, :count) == initial_count
    end
  end
end
