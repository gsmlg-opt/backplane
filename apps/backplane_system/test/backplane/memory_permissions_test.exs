defmodule Backplane.MemoryPermissionsTest do
  use ExUnit.Case, async: true

  alias Backplane.MemoryPermissions
  alias Backplane.MemoryToolContract

  test "delegates the complete memory permission map to the shared contract" do
    assert MemoryPermissions.tool_permissions() == MemoryToolContract.permissions()
    assert MemoryPermissions.for_tool("memory::remember") == {:ok, "memory.write"}
    assert MemoryPermissions.for_tool!("memory::slot_read") == "memory.read"
    assert MemoryPermissions.for_tool("memory::unknown") == :error
  end
end
