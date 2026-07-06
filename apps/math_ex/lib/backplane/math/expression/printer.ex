defmodule Backplane.Math.Expression.Printer do
  @moduledoc "Pure-Elixir printer: AST to plain text, LaTeX, and canonical JSON."

  alias Backplane.Math.Expression.Ast

  @spec to_text(Ast.expr()) :: String.t()
  def to_text({:num, %Decimal{} = d}), do: Decimal.to_string(d)
  def to_text({:num, %Complex{} = c}), do: Complex.to_string(c)
  def to_text({:num, n}), do: to_string(n)
  def to_text({:var, a}), do: a
  def to_text({:sym, :pi}), do: "pi"
  def to_text({:sym, :e}), do: "e"
  def to_text({:sym, :i}), do: "i"
  def to_text({:op, :neg, [a]}), do: "-" <> text_with_parens(a)
  def to_text({:op, op, args}), do: Enum.map_join(args, " #{op} ", &text_with_parens/1)
  def to_text({:app, name, args}), do: "#{name}(#{Enum.map_join(args, ", ", &to_text/1)})"

  def to_text({:mat, rows}) do
    body = Enum.map_join(rows, "; ", fn row -> Enum.map_join(row, ", ", &to_text/1) end)
    "[#{body}]"
  end

  def to_text({:set, members}), do: "{" <> Enum.map_join(members, ", ", &to_text/1) <> "}"

  defp text_with_parens({:op, _, _} = expr), do: "(" <> to_text(expr) <> ")"
  defp text_with_parens(other), do: to_text(other)

  @spec to_latex(Ast.expr()) :: String.t()
  def to_latex({:num, %Decimal{} = d}), do: Decimal.to_string(d)
  def to_latex({:num, %Complex{} = c}), do: Complex.to_string(c)
  def to_latex({:num, n}), do: to_string(n)
  def to_latex({:var, a}), do: a
  def to_latex({:sym, :pi}), do: "\\pi"
  def to_latex({:sym, :e}), do: "e"
  def to_latex({:sym, :i}), do: "i"
  def to_latex({:op, :neg, [a]}), do: "-" <> latex_with_parens(a)
  def to_latex({:op, :/, [num, den]}), do: "\\frac{#{to_latex(num)}}{#{to_latex(den)}}"
  def to_latex({:op, :^, [base, exp]}), do: "#{latex_with_parens(base)}^{#{to_latex(exp)}}"

  def to_latex({:op, op, args}) do
    Enum.map_join(args, " #{latex_op(op)} ", &latex_with_parens/1)
  end

  def to_latex({:app, name, args}) do
    "\\#{latex_fn_name(name)}\\left(#{Enum.map_join(args, ", ", &to_latex/1)}\\right)"
  end

  def to_latex({:mat, rows}) do
    body = Enum.map_join(rows, " \\\\ ", fn row -> Enum.map_join(row, " & ", &to_latex/1) end)
    "\\begin{bmatrix}#{body}\\end{bmatrix}"
  end

  def to_latex({:set, members}) do
    "\\left\\{" <> Enum.map_join(members, ", ", &to_latex/1) <> "\\right\\}"
  end

  defp latex_with_parens({:op, op, _} = expr) when op in [:+, :-, :*, :/],
    do: "\\left(#{to_latex(expr)}\\right)"

  defp latex_with_parens(other), do: to_latex(other)

  defp latex_op(:+), do: "+"
  defp latex_op(:-), do: "-"
  defp latex_op(:*), do: "\\cdot"
  defp latex_op(:mod), do: "\\bmod"
  defp latex_op(op), do: to_string(op)

  defp latex_fn_name(:log), do: "ln"
  defp latex_fn_name(name) when name in [:sin, :cos, :tan, :exp, :sqrt], do: Atom.to_string(name)
  defp latex_fn_name(name), do: "operatorname{#{name}}"

  @spec to_json(Ast.expr()) :: map()
  def to_json({:num, n}) when is_integer(n) or is_float(n), do: %{"num" => n}
  def to_json({:num, %Decimal{} = d}), do: %{"num" => Decimal.to_string(d)}
  def to_json({:num, %Complex{} = c}), do: %{"complex" => %{"re" => c.re, "im" => c.im}}
  def to_json({:var, a}), do: %{"var" => a}
  def to_json({:sym, a}), do: %{"sym" => Atom.to_string(a)}

  def to_json({:op, name, args}) do
    %{"op" => op_string(name), "args" => Enum.map(args, &to_json/1)}
  end

  def to_json({:app, name, args}) do
    %{"app" => Atom.to_string(name), "args" => Enum.map(args, &to_json/1)}
  end

  def to_json({:mat, rows}) do
    %{"mat" => Enum.map(rows, fn row -> Enum.map(row, &to_json/1) end)}
  end

  def to_json({:set, members}), do: %{"set" => Enum.map(members, &to_json/1)}

  defp op_string(:+), do: "+"
  defp op_string(:-), do: "-"
  defp op_string(:*), do: "*"
  defp op_string(:/), do: "/"
  defp op_string(:^), do: "^"
  defp op_string(:!), do: "!"
  defp op_string(op), do: Atom.to_string(op)
end
