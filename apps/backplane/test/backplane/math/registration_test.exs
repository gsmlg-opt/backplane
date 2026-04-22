defmodule Backplane.Math.RegistrationTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.ToolRegistry

  test "math::evaluate is registered at boot" do
    names = ToolRegistry.list_all() |> Enum.map(& &1.name)
    assert "math::evaluate" in names
  end

  test "math::evaluate resolves to Backplane.Math.Tools" do
    assert {:native, Backplane.Math.Tools, :evaluate} = ToolRegistry.resolve("math::evaluate")
  end
end
