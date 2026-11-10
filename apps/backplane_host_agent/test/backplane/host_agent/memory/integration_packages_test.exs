defmodule Backplane.HostAgent.Memory.IntegrationPackagesTest do
  use ExUnit.Case, async: true

  alias Backplane.MemoryToolContract

  @integrations Path.expand("../../../../../../integrations/memory", __DIR__)

  test "integrations/memory directory is located" do
    assert File.dir?(@integrations)
  end

  describe "shared" do
    test "INSTRUCTIONS.md equals the canonical resident instruction plus a newline" do
      path = Path.join(@integrations, "shared/INSTRUCTIONS.md")
      assert File.read!(path) == MemoryToolContract.instructions() <> "\n"
    end
  end
end
