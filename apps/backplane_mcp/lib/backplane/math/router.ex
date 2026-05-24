defmodule Backplane.Math.Router do
  @moduledoc "Routes math tool calls to engines with complexity checks and timeouts."

  alias Backplane.Math.Config
  alias Backplane.Math.Engine.Native
  alias Backplane.Math.Expression.Ast
  alias Backplane.Math.Sandbox

  @engines [Native]

  @spec call(String.t(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def call(tool_name, op, params) when is_binary(tool_name) and is_atom(op) and is_map(params) do
    with :ok <- complexity_check(params),
         {:ok, engine} <- pick_engine(op) do
      timeout = Config.tool_timeout(tool_name)

      case Sandbox.run(fn -> engine.run(op, params) end, timeout) do
        {:ok, {:ok, value}} -> {:ok, value}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, :timeout} -> {:error, :timeout}
        {:error, {:exit, reason}} -> {:error, {:engine_crash, reason}}
      end
    end
  end

  @spec complexity_check(map()) :: :ok | {:error, {:complexity_limit, atom(), integer(), integer()}}
  def complexity_check(params) do
    cfg = Config.get()

    with :ok <- check_ast(params, :max_expr_nodes, &Ast.size/1, cfg.max_expr_nodes),
         :ok <- check_ast(params, :max_expr_depth, &Ast.depth/1, cfg.max_expr_depth),
         :ok <- check_ast(params, :max_integer_bits, &Ast.max_integer_bits/1, cfg.max_integer_bits) do
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

  defp pick_engine(op) do
    case Enum.find(@engines, & &1.supports?(op)) do
      nil -> {:error, {:engine_unavailable, op}}
      engine -> {:ok, engine}
    end
  end
end
