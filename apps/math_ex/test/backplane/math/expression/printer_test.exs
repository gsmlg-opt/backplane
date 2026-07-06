defmodule Backplane.Math.Expression.PrinterTest do
  use ExUnit.Case, async: true

  alias Backplane.Math.Expression.Printer

  test "prints plain text" do
    assert Printer.to_text({:num, 42}) == "42"
    assert Printer.to_text({:var, "x"}) == "x"
    assert Printer.to_text({:sym, :pi}) == "pi"
    assert Printer.to_text({:op, :+, [{:num, 1}, {:num, 2}]}) == "1 + 2"
    assert Printer.to_text({:op, :neg, [{:var, "x"}]}) == "-x"
    assert Printer.to_text({:app, :sin, [{:var, "x"}]}) == "sin(x)"
  end

  test "prints LaTeX" do
    assert Printer.to_latex({:num, 42}) == "42"
    assert Printer.to_latex({:op, :/, [{:num, 1}, {:num, 2}]}) == "\\frac{1}{2}"
    assert Printer.to_latex({:op, :^, [{:var, "x"}, {:num, 2}]}) == "x^{2}"
    assert Printer.to_latex({:sym, :pi}) == "\\pi"
    assert Printer.to_latex({:app, :sin, [{:var, "x"}]}) == "\\sin\\left(x\\right)"
  end

  test "prints JSON that ParserJson can parse" do
    ast = {:op, :+, [{:num, 1}, {:app, :sin, [{:var, "x"}]}]}
    assert {:ok, ^ast} = Backplane.Math.Expression.ParserJson.parse(Printer.to_json(ast))
  end

  test "complex JSON round-trips" do
    ast = {:num, Complex.new(0, 1)}
    assert {:ok, {:num, %Complex{} = complex}} = Backplane.Math.Expression.ParserJson.parse(Printer.to_json(ast))
    assert complex == Complex.new(0, 1)
  end
end
