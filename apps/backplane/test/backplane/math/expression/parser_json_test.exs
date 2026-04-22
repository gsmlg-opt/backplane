defmodule Backplane.Math.Expression.ParserJsonTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.ParserJson

  test "parses literals, variables, and symbols" do
    assert {:ok, {:num, 3}} = ParserJson.parse(%{"num" => 3})
    assert {:ok, {:num, 3.14}} = ParserJson.parse(%{"num" => 3.14})
    assert {:ok, {:var, :x}} = ParserJson.parse(%{"var" => "x"})
    assert {:ok, {:sym, :pi}} = ParserJson.parse(%{"sym" => "pi"})
  end

  test "parses nested op and app expressions" do
    assert {:ok, {:op, :+, [{:num, 1}, {:num, 2}]}} =
             ParserJson.parse(%{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]})

    assert {:ok, {:app, :sin, [{:var, :x}]}} =
             ParserJson.parse(%{"app" => "sin", "args" => [%{"var" => "x"}]})
  end

  test "parses matrix literals" do
    json = %{"mat" => [[%{"num" => 1}, %{"num" => 2}], [%{"num" => 3}, %{"num" => 4}]]}

    assert {:ok, {:mat, [[{:num, 1}, {:num, 2}], [{:num, 3}, {:num, 4}]]}} =
             ParserJson.parse(json)
  end

  test "rejects malformed or invalid input" do
    assert {:error, {:parse, :invalid_ast, _}} =
             ParserJson.parse(%{"app" => "sin", "args" => [%{"num" => 1}, %{"num" => 2}]})

    assert {:error, {:parse, :unknown_tag, "widget"}} = ParserJson.parse(%{"widget" => %{}})
    assert {:error, {:parse, :not_a_map, _}} = ParserJson.parse("not a map")
  end
end
