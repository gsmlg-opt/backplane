defmodule Backplane.Math.RegistrationTest do
  use Backplane.DataCase, async: false

  alias Backplane.Registry.ToolRegistry

  test "math::evaluate is registered at boot" do
    names = ToolRegistry.list_all() |> Enum.map(& &1.name)
    assert "math::evaluate" in names
  end

  test "math::evaluate resolves to managed handler" do
    assert {:managed, handler} = ToolRegistry.resolve("math::evaluate")
    assert is_function(handler, 1)
  end

  test "math::evaluate deregisters when disabled" do
    {:ok, _} = Backplane.Math.Config.save(%{enabled: false})
    assert :not_found = ToolRegistry.resolve("math::evaluate")
    {:ok, _} = Backplane.Math.Config.save(%{enabled: true})
    assert {:managed, _handler} = ToolRegistry.resolve("math::evaluate")
  end
end
