defmodule Backplane.Math.Expression.ParserInfix do
  @moduledoc "Recursive-descent parser for a small infix math expression grammar."

  alias Backplane.Math.Expression.Ast

  @type token :: {:num, number()} | {:ident, String.t()} | String.t()

  @spec parse(String.t()) :: {:ok, Ast.expr()} | {:error, {:parse, term(), term()}}
  def parse(input) when is_binary(input) do
    with {:ok, tokens} <- tokenize(input),
         {:ok, ast, []} <- parse_expr(tokens) do
      if Ast.well_formed?(ast) do
        {:ok, ast}
      else
        {:error, {:parse, :invalid_ast, ast}}
      end
    else
      {:ok, _ast, rest} -> {:error, {:parse, :trailing_input, rest}}
      {:error, reason, rest} -> {:error, {:parse, reason, rest}}
      {:error, reason} -> {:error, {:parse, reason, input}}
    end
  end

  def parse(other), do: {:error, {:parse, :not_a_string, other}}

  defp parse_expr(tokens), do: parse_add(tokens)

  defp parse_add(tokens) do
    with {:ok, left, rest} <- parse_mul(tokens) do
      parse_left_assoc(left, rest, ["+", "-"], &parse_mul/1)
    end
  end

  defp parse_mul(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens) do
      parse_left_assoc(left, rest, ["*", "/"], &parse_unary/1)
    end
  end

  defp parse_unary(["-" | rest]) do
    with {:ok, inner, after_inner} <- parse_pow(rest) do
      {:ok, {:op, :neg, [inner]}, after_inner}
    end
  end

  defp parse_unary(tokens), do: parse_pow(tokens)

  defp parse_pow(tokens) do
    with {:ok, base, rest} <- parse_call(tokens) do
      case rest do
        ["^" | after_op] ->
          with {:ok, exp, after_exp} <- parse_unary(after_op) do
            {:ok, {:op, :^, [base, exp]}, after_exp}
          end

        _ ->
          {:ok, base, rest}
      end
    end
  end

  defp parse_call(tokens) do
    with {:ok, atom, rest} <- parse_atom(tokens) do
      case {atom, rest} do
        {{:ident, name}, ["(" | after_lparen]} ->
          with {:ok, app_name} <- known_app(name),
               {:ok, args, after_args} <- parse_arglist(after_lparen) do
            {:ok, {:app, app_name, args}, after_args}
          end

        {{:ident, name}, _} ->
          {:ok, ident_to_ast(name), rest}

        {other, ["(" | _]} ->
          {:error, {:non_callable, other}, rest}

        {other, _} ->
          {:ok, other, rest}
      end
    end
  end

  defp parse_atom([{:num, n} | rest]), do: {:ok, {:num, n}, rest}
  defp parse_atom([{:ident, name} | rest]), do: {:ok, {:ident, name}, rest}

  defp parse_atom(["(" | rest]) do
    with {:ok, ast, after_expr} <- parse_expr(rest) do
      case after_expr do
        [")" | after_paren] -> {:ok, ast, after_paren}
        other -> {:error, :unterminated_paren, other}
      end
    end
  end

  defp parse_atom([]), do: {:error, :unexpected_eof, []}
  defp parse_atom([token | rest]), do: {:error, {:unexpected_token, token}, rest}

  defp parse_left_assoc(left, [op | rest], ops, next_parser) do
    if op in ops do
      with {:ok, right, after_right} <- next_parser.(rest) do
        parse_left_assoc({:op, op_atom(op), [left, right]}, after_right, ops, next_parser)
      end
    else
      {:ok, left, [op | rest]}
    end
  end

  defp parse_left_assoc(left, rest, _ops, _next_parser), do: {:ok, left, rest}

  defp parse_arglist([")" | rest]), do: {:ok, [], rest}

  defp parse_arglist(tokens) do
    with {:ok, first, rest} <- parse_expr(tokens) do
      parse_argtail([first], rest)
    end
  end

  defp parse_argtail(acc, ["," | rest]) do
    with {:ok, next, after_next} <- parse_expr(rest) do
      parse_argtail([next | acc], after_next)
    end
  end

  defp parse_argtail(acc, [")" | rest]), do: {:ok, Enum.reverse(acc), rest}
  defp parse_argtail(_acc, rest), do: {:error, :unterminated_call, rest}

  defp ident_to_ast("i"), do: {:sym, :i}
  defp ident_to_ast("pi"), do: {:sym, :pi}
  defp ident_to_ast("e"), do: {:sym, :e}
  defp ident_to_ast(name), do: {:var, name}

  defp op_atom("+"), do: :+
  defp op_atom("-"), do: :-
  defp op_atom("*"), do: :*
  defp op_atom("/"), do: :/

  defp known_app(name) do
    case Ast.known_app(name) do
      {:ok, app} -> {:ok, app}
      :error -> {:error, :unknown_function, name}
    end
  end

  defp tokenize(input), do: input |> String.to_charlist() |> do_tokenize([])

  defp do_tokenize([], []), do: {:error, :empty_input}
  defp do_tokenize([], acc), do: {:ok, Enum.reverse(acc)}
  defp do_tokenize([ch | rest], acc) when ch in ~c" \t\r\n", do: do_tokenize(rest, acc)

  defp do_tokenize([ch | _rest] = chars, acc) when ch in ?0..?9 do
    {literal, tail} = take_number(chars, [])

    token =
      if ?. in literal do
        {:num, literal |> to_string() |> String.to_float()}
      else
        {:num, literal |> to_string() |> String.to_integer()}
      end

    do_tokenize(tail, [token | acc])
  end

  defp do_tokenize([ch | _rest] = chars, acc) when ch in ?a..?z or ch in ?A..?Z or ch == ?_ do
    {literal, tail} = take_ident(chars, [])
    do_tokenize(tail, [{:ident, to_string(literal)} | acc])
  end

  defp do_tokenize([ch | rest], acc) when ch in ~c"+-*/^(),",
    do: do_tokenize(rest, [<<ch>> | acc])

  defp do_tokenize([ch | rest], _acc),
    do: {:error, {:bad_character, <<ch::utf8>>, to_string(rest)}}

  defp take_number([ch | rest], acc) when ch in ?0..?9, do: take_number(rest, [ch | acc])

  defp take_number([?. | rest], acc) do
    case acc do
      [] -> {Enum.reverse(acc), [?. | rest]}
      _ -> take_fraction(rest, [?. | acc])
    end
  end

  defp take_number(rest, acc), do: {Enum.reverse(acc), rest}

  defp take_fraction([ch | rest], acc) when ch in ?0..?9, do: take_fraction(rest, [ch | acc])
  defp take_fraction(rest, acc), do: {Enum.reverse(acc), rest}

  defp take_ident([ch | rest], acc)
       when ch in ?a..?z or ch in ?A..?Z or ch in ?0..?9 or ch == ?_ do
    take_ident(rest, [ch | acc])
  end

  defp take_ident(rest, acc), do: {Enum.reverse(acc), rest}
end
