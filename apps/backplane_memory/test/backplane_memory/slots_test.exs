defmodule BackplaneMemory.SlotsTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.Slots
  alias BackplaneMemory.Slots.Slot

  describe "write/3" do
    test "stores content in a new slot" do
      assert {:ok, slot} = Slots.write("self_notes", "remember to hydrate", "test_actor")
      assert slot.name == "self_notes"
      assert slot.content == "remember to hydrate"
      assert slot.updated_by == "test_actor"
    end

    test "creates a new slot if name does not exist yet" do
      name = "custom_slot_#{System.unique_integer([:positive])}"
      assert {:ok, slot} = Slots.write(name, "some content")
      assert slot.name == name
      assert slot.content == "some content"
    end

    test "overwrites existing slot content" do
      name = "guidance"
      {:ok, _} = Slots.write(name, "first content")
      assert {:ok, slot} = Slots.write(name, "second content", "updater")
      assert slot.content == "second content"
      assert slot.updated_by == "updater"
    end

    test "fails when content exceeds size_limit_chars" do
      # Default size_limit_chars is 2000; write a slot with a tiny limit first
      repo = repo()
      name = "tiny_slot_#{System.unique_integer([:positive])}"

      repo.insert!(%Slot{
        name: name,
        content: "",
        updated_at: DateTime.utc_now(),
        size_limit_chars: 10
      })

      assert {:error, changeset} = Slots.write(name, String.duplicate("x", 11))
      assert errors_on(changeset)[:content] != nil
    end
  end

  describe "read/1" do
    test "returns the slot for a known name" do
      {:ok, _} = Slots.write("persona", "I am a helpful assistant")
      assert {:ok, slot} = Slots.read("persona")
      assert slot.content == "I am a helpful assistant"
    end

    test "returns {:error, :not_found} for an unknown slot" do
      assert {:error, :not_found} = Slots.read("nonexistent_slot_xyz")
    end
  end

  describe "list/0" do
    test "returns all slots ordered by name" do
      slots = Slots.list()
      assert is_list(slots)
      # The 8 default slots were seeded by migration
      names = Enum.map(slots, & &1.name)
      assert "guidance" in names
      assert "pending_items" in names
      assert "session_patterns" in names
      assert "self_notes" in names
    end

    test "results are ordered by name ascending" do
      slots = Slots.list()
      names = Enum.map(slots, & &1.name)
      assert names == Enum.sort(names)
    end
  end
end
