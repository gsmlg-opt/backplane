defmodule Backplane.Math.RouterTest do
  use Backplane.DataCase, async: false

  alias Backplane.Math.Config
  alias Backplane.Math.Router

  setup do
    Backplane.Repo.delete_all(Backplane.Math.Config.Record)
    :ok = Config.reload()
    :ok
  end

  test "dispatches evaluate to the native engine" do
    assert {:ok, 3} = Router.call("math::evaluate", :evaluate, %{ast: {:op, :+, [{:num, 1}, {:num, 2}]}})
  end

  test "returns engine unavailable when no engine supports the op" do
    assert {:error, {:engine_unavailable, :integrate}} = Router.call("integrate", :integrate, %{})
  end

  test "enforces expression caps" do
    {:ok, _} = Config.save(%{max_expr_nodes: 3})
    huge = {:op, :+, [{:num, 1}, {:op, :+, [{:num, 2}, {:num, 3}]}]}
    assert {:error, {:complexity_limit, :max_expr_nodes, actual, 3}} = Router.call("math::evaluate", :evaluate, %{ast: huge})
    assert actual > 3

    {:ok, _} = Config.save(%{max_expr_nodes: 10_000, max_expr_depth: 2})
    deep = {:op, :+, [{:op, :+, [{:num, 1}, {:num, 2}]}, {:num, 3}]}
    assert {:error, {:complexity_limit, :max_expr_depth, _, 2}} = Router.call("math::evaluate", :evaluate, %{ast: deep})

    {:ok, _} = Config.save(%{max_expr_depth: 64, max_integer_bits: 8})
    assert {:error, {:complexity_limit, :max_integer_bits, _, 8}} = Router.call("math::evaluate", :evaluate, %{ast: {:num, 1_000}})
  end
end
