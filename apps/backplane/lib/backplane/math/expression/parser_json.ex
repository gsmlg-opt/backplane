defmodule Backplane.Math.Expression.ParserJson do
  @moduledoc "Converts JSON-shaped AST input into the canonical math AST."

  alias Backplane.Math.Expression.Ast

  @spec parse(term()) :: {:ok, Ast.expr()} | {:error, term()}
  def parse(json) do
    with {:ok, ast} <- to_ast(json) do
      if Ast.well_formed?(ast) do
        {:ok, ast}
      else
        {:error, {:parse, :invalid_ast, ast}}
      end
    end
  end

  defp to_ast(n) when is_integer(n) or is_float(n), do: {:ok, {:num, n}}

  defp to_ast(map) when is_map(map) do
    cond do
      Map.has_key?(map, "num") -> wrap_num(map["num"])
      Map.has_key?(map, "complex") -> wrap_complex(map["complex"])
      Map.has_key?(map, "var") -> wrap_var(map["var"])
      Map.has_key?(map, "sym") -> wrap_sym(map["sym"])
      Map.has_key?(map, "op") -> wrap_children(:op, map["op"], map["args"])
      Map.has_key?(map, "app") -> wrap_children(:app, map["app"], map["args"])
      Map.has_key?(map, "mat") -> wrap_mat(map["mat"])
      Map.has_key?(map, "set") -> wrap_set(map["set"])
      true -> {:error, {:parse, :unknown_tag, Map.keys(map) |> List.first()}}
    end
  end

  defp to_ast(other), do: {:error, {:parse, :not_a_map, other}}

  defp wrap_num(n) when is_integer(n) or is_float(n), do: {:ok, {:num, n}}

  defp wrap_num(n) when is_binary(n) do
    case Decimal.parse(n) do
      {decimal, ""} -> {:ok, {:num, decimal}}
      _ -> {:error, {:parse, :bad_num, n}}
    end
  end

  defp wrap_num(other), do: {:error, {:parse, :bad_num, other}}

  defp wrap_complex(%{"re" => re, "im" => im}) when is_number(re) and is_number(im),
    do: {:ok, {:num, Complex.new(re, im)}}

  defp wrap_complex(other), do: {:error, {:parse, :bad_complex, other}}

  defp wrap_var(name) when is_binary(name) and name != "", do: {:ok, {:var, name}}
  defp wrap_var(other), do: {:error, {:parse, :bad_var, other}}

  defp wrap_sym(name) when is_binary(name) do
    case Ast.known_symbol(name) do
      {:ok, symbol} -> {:ok, {:sym, symbol}}
      :error -> {:error, {:parse, :bad_sym, name}}
    end
  end

  defp wrap_sym(other), do: {:error, {:parse, :bad_sym, other}}

  defp wrap_children(tag, name, args) when is_binary(name) and is_list(args) do
    with {:ok, parsed} <- parse_list(args),
         {:ok, op_name} <- resolve_name(tag, name) do
      {:ok, {tag, op_name, parsed}}
    end
  end

  defp wrap_children(_tag, _name, other), do: {:error, {:parse, :bad_children, other}}

  defp wrap_mat(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case row do
        cells when is_list(cells) ->
          case parse_list(cells) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, _} = err -> {:halt, err}
          end

        other ->
          {:halt, {:error, {:parse, :bad_mat_row, other}}}
      end
    end)
    |> case do
      {:ok, parsed_rows} -> {:ok, {:mat, Enum.reverse(parsed_rows)}}
      {:error, _} = err -> err
    end
  end

  defp wrap_mat(other), do: {:error, {:parse, :bad_mat, other}}

  defp wrap_set(members) when is_list(members) do
    with {:ok, parsed} <- parse_list(members), do: {:ok, {:set, parsed}}
  end

  defp wrap_set(other), do: {:error, {:parse, :bad_set, other}}

  defp parse_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case to_ast(child) do
        {:ok, ast} -> {:cont, {:ok, [ast | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = err -> err
    end
  end

  defp resolve_name(:op, name) do
    case Ast.known_op(name) do
      {:ok, op} -> {:ok, op}
      :error -> {:error, {:parse, :bad_op, name}}
    end
  end

  defp resolve_name(:app, name) do
    case Ast.known_app(name) do
      {:ok, app} -> {:ok, app}
      :error -> {:error, {:parse, :bad_app, name}}
    end
  end
end
