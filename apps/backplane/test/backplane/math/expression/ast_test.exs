defmodule Backplane.Math.Expression.AstTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.Ast

  test "well_formed?/1 accepts numeric leaves" do
    assert Ast.well_formed?({:num, 1})
    assert Ast.well_formed?({:num, 1.5})
    assert Ast.well_formed?({:num, Decimal.new("3.14")})
    assert Ast.well_formed?({:num, Complex.new(1, 2)})
    refute Ast.well_formed?({:num, "1"})
  end

  test "well_formed?/1 validates variables and symbols" do
    assert Ast.well_formed?({:var, :x})
    refute Ast.well_formed?({:var, "x"})
    assert Ast.well_formed?({:sym, :pi})
    refute Ast.well_formed?({:sym, :tau})
  end

  test "well_formed?/1 validates op and app children" do
    assert Ast.well_formed?({:op, :+, [{:num, 1}, {:num, 2}]})
    refute Ast.well_formed?({:op, :+, [{:num, 1}, "two"]})
    assert Ast.well_formed?({:app, :sin, [{:var, :x}]})
    refute Ast.well_formed?({:app, :sin, [{:var, :x}, {:var, :y}]})
  end

  test "well_formed?/1 validates matrix rectangularity" do
    assert Ast.well_formed?({:mat, [[{:num, 1}, {:num, 2}], [{:num, 3}, {:num, 4}]]})
    refute Ast.well_formed?({:mat, [[{:num, 1}, {:num, 2}], [{:num, 3}]]})
  end

  test "size/1 counts every node" do
    assert Ast.size({:num, 1}) == 1
    assert Ast.size({:op, :+, [{:num, 1}, {:num, 2}]}) == 3
    assert Ast.size({:op, :+, [{:op, :*, [{:num, 1}, {:num, 2}]}, {:num, 3}]}) == 5
  end

  test "depth/1 computes maximum nesting depth" do
    assert Ast.depth({:num, 1}) == 1
    assert Ast.depth({:op, :+, [{:num, 1}, {:num, 2}]}) == 2
    assert Ast.depth({:op, :+, [{:op, :*, [{:num, 1}, {:num, 2}]}, {:num, 3}]}) == 3
  end

  test "max_integer_bits/1 returns largest integer bit width" do
    assert Ast.max_integer_bits({:num, 7}) == 3
    assert Ast.max_integer_bits({:op, :+, [{:num, 1}, {:num, 1_000_000}]}) == 20
    assert Ast.max_integer_bits({:num, 1.5}) == 0
  end
end
