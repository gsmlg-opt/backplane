defmodule Backplane.HostAgent.Services.Math do
  @moduledoc """
  Local MCP service for numerical math evaluation via math_ex.
  """

  @behaviour Backplane.HostAgent.LocalService

  alias Backplane.Math.Engine.Native
  alias Backplane.Math.Expression.{Ast, ParserInfix, ParserJson, Printer}

  @max_expr_nodes 10_000
  @max_expr_depth 64
  @max_integer_bits 4_096

  @impl true
  def prefix, do: "math"

  @impl true
  def tools do
    [
      %{
        "name" => "math::evaluate",
        "description" =>
          "Numerically evaluate a math expression from an infix string or canonical JSON AST.",
        "inputSchema" => %{
          "type" => "object",
          "oneOf" => [
            %{"required" => ["expr"]},
            %{"required" => ["ast"]}
          ],
          "properties" => %{
            "expr" => %{
              "type" => "string",
              "description" => "Infix expression, for example \"2 * (3 + 4)\"."
            },
            "ast" => %{
              "type" => "object",
              "description" => "Canonical JSON AST."
            },
            "vars" => %{
              "type" => "object",
              "description" => "Variable bindings.",
              "additionalProperties" => %{"type" => "number"}
            }
          }
        }
      }
    ]
  end

  @impl true
  def call("evaluate", args, _ctx) when is_map(args), do: handle_evaluate(args)
  def call(method, _args, _ctx) when is_binary(method), do: {:error, {:unknown_method, method}}

  def handle_evaluate(args) do
    with {:ok, ast} <- parse_expression(args),
         :ok <- complexity_check(%{ast: ast}),
         {:ok, vars} <- parse_vars(args),
         {:ok, value} <- Native.run(:evaluate, %{ast: ast, vars: vars}) do
      value_ast = value_to_ast(value)

      {:ok,
       %{
         "value" => jsonable(value),
         "ast" => Printer.to_json(value_ast),
         "latex" => Printer.to_latex(value_ast),
         "text" => Printer.to_text(value_ast)
       }}
    end
  end

  defp parse_expression(%{"ast" => json}) when is_map(json), do: ParserJson.parse(json)
  defp parse_expression(%{"expr" => expr}) when is_binary(expr), do: ParserInfix.parse(expr)
  defp parse_expression(_args), do: {:error, {:bad_request, :missing_expression}}

  defp parse_vars(%{"vars" => vars}) when is_map(vars) do
    vars
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, {:bad_request, {:var_name, key}}}}

        not (is_integer(value) or is_float(value)) ->
          {:halt, {:error, {:bad_request, {:var_value, key, value}}}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp parse_vars(_args), do: {:ok, %{}}

  defp complexity_check(params) do
    with :ok <- check_ast(params, :max_expr_nodes, &Ast.size/1, @max_expr_nodes),
         :ok <- check_ast(params, :max_expr_depth, &Ast.depth/1, @max_expr_depth),
         :ok <- check_ast(params, :max_integer_bits, &Ast.max_integer_bits/1, @max_integer_bits) do
      :ok
    end
  end

  defp check_ast(%{ast: ast}, cap, measure, limit) do
    actual = measure.(ast)

    if actual <= limit do
      :ok
    else
      {:error, {:complexity_limit, cap, actual, limit}}
    end
  end

  defp check_ast(_params, _cap, _measure, _limit), do: :ok

  defp value_to_ast(value) when is_integer(value) or is_float(value), do: {:num, value}
  defp value_to_ast(%Decimal{} = value), do: {:num, value}
  defp value_to_ast(%Complex{} = value), do: {:num, value}
  defp value_to_ast(:infinity), do: {:sym, :inf}
  defp value_to_ast(:nan), do: {:sym, :nan}
  defp value_to_ast(other), do: {:num, other}

  defp jsonable(value)
       when is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
              is_nil(value),
       do: value

  defp jsonable(%Decimal{} = value), do: Decimal.to_string(value)
  defp jsonable(%Complex{} = value), do: Complex.to_string(value)
  defp jsonable(:infinity), do: "infinity"
  defp jsonable(:nan), do: "nan"
  defp jsonable(other), do: inspect(other)
end
