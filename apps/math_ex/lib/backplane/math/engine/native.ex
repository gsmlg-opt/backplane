defmodule Backplane.Math.Engine.Native do
  @moduledoc "Native Elixir math engine. Phase 1 supports numeric evaluation."

  @behaviour Backplane.Math.Engine

  @supported MapSet.new([:evaluate])

  @impl true
  def describe, do: %{id: :native, version: "0.1.0"}

  @impl true
  def supports?(op) when is_atom(op), do: MapSet.member?(@supported, op)

  @impl true
  def run(:evaluate, %{ast: ast} = params) do
    vars = Map.get(params, :vars, %{})

    try do
      {:ok, eval(ast, vars)}
    rescue
      error -> {:error, {:eval_error, Exception.message(error)}}
    catch
      {:unbound_var, _} = err -> {:error, err}
      {:eval_error, reason} -> {:error, {:eval_error, reason}}
    end
  end

  def run(op, _params), do: {:error, {:unsupported_op, op}}

  defp eval({:num, n}, _vars) when is_integer(n) or is_float(n), do: n
  defp eval({:num, %Decimal{} = d}, _vars), do: d
  defp eval({:num, %Complex{} = c}, _vars), do: c

  defp eval({:var, name}, vars) do
    case Map.fetch(vars, name) do
      {:ok, value} -> value
      :error -> throw({:unbound_var, name})
    end
  end

  defp eval({:sym, :pi}, _vars), do: :math.pi()
  defp eval({:sym, :e}, _vars), do: :math.exp(1.0)
  defp eval({:sym, :i}, _vars), do: Complex.new(0, 1)

  defp eval({:op, :neg, [a]}, vars), do: negate(eval(a, vars))

  defp eval({:op, :+, args}, vars),
    do: args |> Enum.map(&eval(&1, vars)) |> Enum.reduce(0, &add/2)

  defp eval({:op, :-, [a, b]}, vars), do: subtract(eval(a, vars), eval(b, vars))
  defp eval({:op, :-, [a]}, vars), do: negate(eval(a, vars))

  defp eval({:op, :*, args}, vars),
    do: args |> Enum.map(&eval(&1, vars)) |> Enum.reduce(1, &multiply/2)

  defp eval({:op, :/, [a, b]}, vars), do: divide(eval(a, vars), eval(b, vars))

  defp eval({:op, :^, [a, b]}, vars),
    do: :math.pow(as_float(eval(a, vars)), as_float(eval(b, vars)))

  defp eval({:op, :mod, [a, b]}, vars), do: rem(eval(a, vars), eval(b, vars))

  defp eval({:app, :sin, [a]}, vars), do: :math.sin(as_float(eval(a, vars)))
  defp eval({:app, :cos, [a]}, vars), do: :math.cos(as_float(eval(a, vars)))
  defp eval({:app, :tan, [a]}, vars), do: :math.tan(as_float(eval(a, vars)))
  defp eval({:app, :exp, [a]}, vars), do: :math.exp(as_float(eval(a, vars)))
  defp eval({:app, :log, [a]}, vars), do: :math.log(as_float(eval(a, vars)))
  defp eval({:app, :log10, [a]}, vars), do: :math.log10(as_float(eval(a, vars)))
  defp eval({:app, :log2, [a]}, vars), do: :math.log2(as_float(eval(a, vars)))
  defp eval({:app, :sqrt, [a]}, vars), do: :math.sqrt(as_float(eval(a, vars)))
  defp eval({:app, :abs, [a]}, vars), do: abs(eval(a, vars))

  defp eval({:app, :floor, [a]}, vars),
    do: eval(a, vars) |> as_float() |> Float.floor() |> trunc()

  defp eval({:app, :ceil, [a]}, vars), do: eval(a, vars) |> as_float() |> Float.ceil() |> trunc()
  defp eval({:app, :min, args}, vars), do: args |> Enum.map(&eval(&1, vars)) |> Enum.min()
  defp eval({:app, :max, args}, vars), do: args |> Enum.map(&eval(&1, vars)) |> Enum.max()

  defp eval(other, _vars), do: throw({:eval_error, {:unhandled, other}})

  defp add(%Complex{} = a, b), do: Complex.add(a, b)
  defp add(a, %Complex{} = b), do: Complex.add(a, b)
  defp add(%Decimal{} = a, %Decimal{} = b), do: Decimal.add(a, b)
  defp add(%Decimal{} = a, b) when is_integer(b), do: Decimal.add(a, Decimal.new(b))
  defp add(a, %Decimal{} = b) when is_integer(a), do: Decimal.add(Decimal.new(a), b)
  defp add(a, b), do: a + b

  defp subtract(%Complex{} = a, b), do: Complex.subtract(a, b)
  defp subtract(a, %Complex{} = b), do: Complex.subtract(a, b)
  defp subtract(%Decimal{} = a, %Decimal{} = b), do: Decimal.sub(a, b)
  defp subtract(%Decimal{} = a, b) when is_integer(b), do: Decimal.sub(a, Decimal.new(b))
  defp subtract(a, %Decimal{} = b) when is_integer(a), do: Decimal.sub(Decimal.new(a), b)
  defp subtract(a, b), do: a - b

  defp multiply(%Complex{} = a, b), do: Complex.multiply(a, b)
  defp multiply(a, %Complex{} = b), do: Complex.multiply(a, b)
  defp multiply(%Decimal{} = a, %Decimal{} = b), do: Decimal.mult(a, b)
  defp multiply(%Decimal{} = a, b) when is_integer(b), do: Decimal.mult(a, Decimal.new(b))
  defp multiply(a, %Decimal{} = b) when is_integer(a), do: Decimal.mult(Decimal.new(a), b)
  defp multiply(a, b), do: a * b

  defp divide(%Complex{} = a, b), do: Complex.divide(a, b)
  defp divide(a, %Complex{} = b), do: Complex.divide(a, b)
  defp divide(%Decimal{} = a, %Decimal{} = b), do: Decimal.div(a, b)
  defp divide(%Decimal{} = a, b) when is_integer(b), do: Decimal.div(a, Decimal.new(b))
  defp divide(a, %Decimal{} = b) when is_integer(a), do: Decimal.div(Decimal.new(a), b)
  defp divide(a, b), do: a / b

  defp negate(%Complex{} = value), do: Complex.multiply(value, -1)
  defp negate(%Decimal{} = value), do: Decimal.negate(value)
  defp negate(value), do: -value

  defp as_float(value) when is_integer(value), do: value * 1.0
  defp as_float(value) when is_float(value), do: value
  defp as_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp as_float(other), do: throw({:eval_error, {:expected_real_number, other}})
end
