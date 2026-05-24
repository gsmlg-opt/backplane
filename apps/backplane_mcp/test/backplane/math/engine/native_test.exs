defmodule Backplane.Math.Engine.NativeTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Engine.Native

  test "describe/0 and supports?/1 report native evaluate support" do
    assert %{id: :native, version: _} = Native.describe()
    assert Native.supports?(:evaluate)
    refute Native.supports?(:integrate)
  end

  test "evaluates arithmetic expressions" do
    assert {:ok, 42} = Native.run(:evaluate, %{ast: {:num, 42}})
    assert {:ok, 3} = Native.run(:evaluate, %{ast: {:op, :+, [{:num, 1}, {:num, 2}]}})

    ast = {:op, :+, [{:num, 1}, {:op, :*, [{:num, 2}, {:num, 3}]}]}
    assert {:ok, 7} = Native.run(:evaluate, %{ast: ast})
    assert {:ok, -5} = Native.run(:evaluate, %{ast: {:op, :neg, [{:num, 5}]}})
  end

  test "evaluates functions, constants, and variables" do
    assert {:ok, val} = Native.run(:evaluate, %{ast: {:app, :sin, [{:num, 0}]}})
    assert_in_delta val, 0.0, 1.0e-12

    assert {:ok, 3} = Native.run(:evaluate, %{ast: {:op, :+, [{:var, "x"}, {:num, 1}]}, vars: %{"x" => 2}})
    assert {:error, {:unbound_var, "y"}} = Native.run(:evaluate, %{ast: {:var, "y"}})

    assert {:ok, val_pi} = Native.run(:evaluate, %{ast: {:sym, :pi}})
    assert_in_delta val_pi, :math.pi(), 1.0e-12
  end

  test "preserves Decimal arithmetic for exact decimal inputs" do
    ast = {:op, :+, [{:num, Decimal.new("0.1")}, {:num, Decimal.new("0.2")}]}
    assert {:ok, %Decimal{} = value} = Native.run(:evaluate, %{ast: ast})
    assert Decimal.equal?(value, Decimal.new("0.3"))
  end

  test "returns unsupported op errors" do
    assert {:error, {:unsupported_op, :integrate}} = Native.run(:integrate, %{})
  end
end
