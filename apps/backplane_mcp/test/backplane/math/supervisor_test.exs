defmodule Backplane.Math.SupervisorTest do
  use ExUnit.Case, async: false

  test "Backplane.Math.Supervisor is running" do
    assert pid = Process.whereis(Backplane.Math.Supervisor)
    assert Process.alive?(pid)
  end

  test "supervises Config and Sandbox" do
    children = Supervisor.which_children(Backplane.Math.Supervisor)
    names = Enum.map(children, fn {name, _pid, _type, _modules} -> name end)

    assert Backplane.Math.Config in names
    assert Backplane.Math.Sandbox in names
  end
end
