defmodule Backplane.MemoryToolContractTest do
  use ExUnit.Case, async: true

  alias Backplane.MemoryToolContract

  @five ~w(memory::search memory::get memory::recent memory::remember memory::forget)

  test "instructions/0 is the canonical resident instruction" do
    instructions = MemoryToolContract.instructions()

    assert String.starts_with?(
             instructions,
             "Backplane Memory is shared by all of the user's agents and hosts.\n"
           )

    assert instructions =~ "call memory::search"
    assert instructions =~ "call memory::remember once"
    assert instructions =~ "call memory::forget with a reason."
    refute String.ends_with?(instructions, "\n")
  end

  test "exposes exactly the five public tools with schemas" do
    assert Enum.sort(MemoryToolContract.tools()) == Enum.sort(@five)
    assert MemoryToolContract.schemas() |> Map.keys() |> Enum.sort() == Enum.sort(@five)
  end

  test "maps read and write tools to the two permission classes" do
    assert MemoryToolContract.permissions() == ["memory.read", "memory.write"]

    for name <- ~w(memory::search memory::get memory::recent),
        do: assert(MemoryToolContract.permission_for(name) == "memory.read")

    for name <- ~w(memory::remember memory::forget),
        do: assert(MemoryToolContract.permission_for(name) == "memory.write")

    assert MemoryToolContract.permission_for("memory::recall") == nil
  end
end
