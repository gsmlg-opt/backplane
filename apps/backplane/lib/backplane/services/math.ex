defmodule Backplane.Services.Math do
  @moduledoc "Managed MCP service for the Math server."

  @behaviour Backplane.Services.ManagedService

  alias Backplane.Math.Expression.{ParserInfix, ParserJson, Printer}
  alias Backplane.Math.Router

  @impl true
  def prefix, do: "math"

  @impl true
  def enabled?, do: Backplane.Math.Config.get(:enabled)

  @impl true
  def tools do
    [
      %{
        name: "math::evaluate",
        description:
          "Numerically evaluate a math expression from an infix string or canonical JSON AST.",
        input_schema: %{
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
        },
        handler: &handle_evaluate/1
      }
    ]
  end

  def handle_evaluate(args) do
    with :ok <- ensure_enabled(),
         {:ok, ast} <- parse_expression(args),
         {:ok, vars} <- parse_vars(args),
         {:ok, value} <- Router.call("math::evaluate", :evaluate, %{ast: ast, vars: vars}) do
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


  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, {:disabled, "math::evaluate"}}
  end

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
