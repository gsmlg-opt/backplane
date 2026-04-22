defmodule Backplane.Math.Expression.Ast do
  @moduledoc """
  Canonical math AST and structural helpers.
  """

  @type expr ::
          {:num, number() | Decimal.t() | Complex.t()}
          | {:var, atom()}
          | {:sym, atom()}
          | {:app, atom(), [expr()]}
          | {:op, atom(), [expr()]}
          | {:mat, [[expr()]]}
          | {:set, [expr()]}

  @known_syms ~w(pi e inf nan i)a

  @known_apps %{
    sin: 1,
    cos: 1,
    tan: 1,
    asin: 1,
    acos: 1,
    atan: 1,
    atan2: 2,
    sinh: 1,
    cosh: 1,
    tanh: 1,
    exp: 1,
    log: 1,
    log10: 1,
    log2: 1,
    logb: 2,
    sqrt: 1,
    cbrt: 1,
    abs: 1,
    sign: 1,
    floor: 1,
    ceil: 1,
    round: 2,
    factorial: 1,
    gamma: 1,
    min: :any,
    max: :any
  }

  @known_ops %{
    :+ => :any,
    :- => :any,
    :* => :any,
    :/ => 2,
    :^ => 2,
    :! => 1,
    :neg => 1,
    :mod => 2
  }

  @spec well_formed?(term()) :: boolean()
  def well_formed?({:num, n}) when is_integer(n) or is_float(n), do: true
  def well_formed?({:num, %Decimal{}}), do: true
  def well_formed?({:num, %Complex{}}), do: true
  def well_formed?({:num, _}), do: false
  def well_formed?({:var, a}) when is_atom(a), do: true
  def well_formed?({:var, _}), do: false
  def well_formed?({:sym, s}) when is_atom(s), do: s in @known_syms
  def well_formed?({:sym, _}), do: false

  def well_formed?({:app, name, args}) when is_atom(name) and is_list(args) do
    valid_arity?(Map.fetch(@known_apps, name), args) and Enum.all?(args, &well_formed?/1)
  end

  def well_formed?({:op, name, args}) when is_atom(name) and is_list(args) do
    valid_arity?(Map.fetch(@known_ops, name), args) and Enum.all?(args, &well_formed?/1)
  end

  def well_formed?({:mat, rows}) when is_list(rows) and rows != [] do
    case rows do
      [first | _] when is_list(first) ->
        cols = length(first)

        cols > 0 and
          Enum.all?(rows, fn row ->
            is_list(row) and length(row) == cols and Enum.all?(row, &well_formed?/1)
          end)

      _ ->
        false
    end
  end

  def well_formed?({:set, members}) when is_list(members),
    do: Enum.all?(members, &well_formed?/1)

  def well_formed?(_), do: false

  defp valid_arity?({:ok, :any}, args), do: args != []
  defp valid_arity?({:ok, arity}, args) when is_integer(arity), do: length(args) == arity
  defp valid_arity?(:error, _args), do: false

  @spec size(expr()) :: non_neg_integer()
  def size({:num, _}), do: 1
  def size({:var, _}), do: 1
  def size({:sym, _}), do: 1
  def size({:app, _, args}), do: 1 + Enum.reduce(args, 0, &(size(&1) + &2))
  def size({:op, _, args}), do: 1 + Enum.reduce(args, 0, &(size(&1) + &2))

  def size({:mat, rows}) do
    1 + Enum.reduce(rows, 0, fn row, acc -> acc + Enum.reduce(row, 0, &(size(&1) + &2)) end)
  end

  def size({:set, members}), do: 1 + Enum.reduce(members, 0, &(size(&1) + &2))

  @spec depth(expr()) :: pos_integer()
  def depth({:num, _}), do: 1
  def depth({:var, _}), do: 1
  def depth({:sym, _}), do: 1
  def depth({:app, _, args}), do: 1 + max_depth(args)
  def depth({:op, _, args}), do: 1 + max_depth(args)
  def depth({:mat, rows}), do: 1 + max_depth(List.flatten(rows))
  def depth({:set, members}), do: 1 + max_depth(members)

  defp max_depth([]), do: 0
  defp max_depth(list), do: list |> Enum.map(&depth/1) |> Enum.max()

  @spec max_integer_bits(expr()) :: non_neg_integer()
  def max_integer_bits({:num, n}) when is_integer(n) and n < 0, do: bit_width(abs(n))
  def max_integer_bits({:num, n}) when is_integer(n), do: bit_width(n)
  def max_integer_bits({:num, _}), do: 0
  def max_integer_bits({:var, _}), do: 0
  def max_integer_bits({:sym, _}), do: 0
  def max_integer_bits({:app, _, args}), do: max_leaf_bits(args)
  def max_integer_bits({:op, _, args}), do: max_leaf_bits(args)
  def max_integer_bits({:mat, rows}), do: max_leaf_bits(List.flatten(rows))
  def max_integer_bits({:set, members}), do: max_leaf_bits(members)

  defp bit_width(0), do: 1
  defp bit_width(n), do: n |> Integer.digits(2) |> length()

  defp max_leaf_bits([]), do: 0
  defp max_leaf_bits(list), do: list |> Enum.map(&max_integer_bits/1) |> Enum.max()
end
