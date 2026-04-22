defmodule Backplane.Math.SandboxTest do
  use ExUnit.Case, async: false

  alias Backplane.Math.Sandbox

  test "returns the function's result on success" do
    assert {:ok, 42} = Sandbox.run(fn -> 42 end, 1_000)
  end

  test "returns timeout when function exceeds deadline" do
    assert {:error, :timeout} = Sandbox.run(fn -> Process.sleep(200) end, 50)
  end

  test "isolates crashes" do
    assert {:error, {:exit, _}} = Sandbox.run(fn -> raise "boom" end, 1_000)
    assert Process.alive?(self())
  end

  test "brutal-kills the task on timeout" do
    parent = self()

    Sandbox.run(
      fn ->
        send(parent, {:child, self()})
        Process.sleep(10_000)
      end,
      50
    )

    assert_receive {:child, pid}, 100
    refute Process.alive?(pid)
  end
end
