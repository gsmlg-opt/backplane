defmodule Backplane.Math.Expression.ParserInfixTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.ParserInfix

  test "parses literals, variables, and constants" do
    assert {:ok, {:num, 42}} = ParserInfix.parse("42")
    assert {:ok, {:num, 3.14}} = ParserInfix.parse("3.14")
    assert {:ok, {:var, :x}} = ParserInfix.parse("x")
    assert {:ok, {:sym, :pi}} = ParserInfix.parse("pi")
    assert {:ok, {:sym, :e}} = ParserInfix.parse("e")
  end

  test "parses arithmetic precedence and parentheses" do
    assert {:ok, {:op, :+, [{:num, 1}, {:num, 2}]}} = ParserInfix.parse("1 + 2")

    assert {:ok, {:op, :+, [{:num, 1}, {:op, :*, [{:num, 2}, {:num, 3}]}]}} =
             ParserInfix.parse("1 + 2 * 3")

    assert {:ok, {:op, :*, [{:op, :+, [{:num, 1}, {:num, 2}]}, {:num, 3}]}} =
             ParserInfix.parse("(1 + 2) * 3")
  end

  test "parses exponent as right associative and unary minus" do
    assert {:ok, {:op, :^, [{:num, 2}, {:op, :^, [{:num, 3}, {:num, 4}]}]}} =
             ParserInfix.parse("2 ^ 3 ^ 4")

    assert {:ok, {:op, :neg, [{:var, :x}]}} = ParserInfix.parse("-x")
    assert {:ok, {:op, :+, [{:num, 1}, {:op, :neg, [{:num, 2}]}]}} = ParserInfix.parse("1 + -2")
  end

  test "parses function applications" do
    assert {:ok, {:app, :sin, [{:var, :x}]}} = ParserInfix.parse("sin(x)")
    assert {:ok, {:app, :atan2, [{:var, :y}, {:var, :x}]}} = ParserInfix.parse("atan2(y, x)")
  end

  test "returns parse errors" do
    assert {:error, {:parse, _, _}} = ParserInfix.parse("1 + (2")
    assert {:error, {:parse, _, _}} = ParserInfix.parse("")
    assert {:error, {:parse, _, _}} = ParserInfix.parse("1 +")
  end
end
