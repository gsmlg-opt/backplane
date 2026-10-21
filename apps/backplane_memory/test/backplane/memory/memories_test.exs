defmodule Backplane.Memory.MemoriesTest do
  use Backplane.Memory.DataCase, async: false
  alias Backplane.Memory.Memories

  test "canonical reads keep source provenance separate from a reader's host and client" do
    partition = canonical_partition("canonical-source", scope: "source_test")

    {:ok, memory} =
      Memories.remember(
        "source preservation fixture",
        Map.to_list(partition) ++ [agent_id: "source-agent"]
      )

    reader = Map.merge(partition, %{host_id: "different-reader", client_id: "different-client"})
    assert {:ok, result} = Memories.get(memory.id, reader)
    assert result.host_id == "canonical-source"
    assert [listed] = Memories.list([], reader)
    assert listed.id == memory.id
    assert {:error, :not_found} = Memories.get(memory.id, %{reader | namespace: "foreign"})
  end
end
