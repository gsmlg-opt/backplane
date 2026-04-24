defmodule Backplane.Services.MathTest do
  use Backplane.DataCase, async: false

  alias Backplane.Services.Math

  setup do
    Backplane.Repo.delete_all(Backplane.Math.Config.Record)
    :ok = Backplane.Math.Config.reload()
    :ok
  end

  test "tools/0 emits math::evaluate with ManagedService-shaped fields" do
    [tool] = Math.tools()
    assert tool.name == "math::evaluate"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert is_function(tool.handler, 1)
  end

  test "handle_evaluate/1 evaluates JSON AST and infix expressions" do
    json_args = %{"ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}}

    assert {:ok, %{"value" => 3, "ast" => %{"num" => 3}, "latex" => "3", "text" => "3"}} =
             Math.handle_evaluate(json_args)

    infix_args = %{"expr" => "2 * (3 + 4)"}
    assert {:ok, %{"value" => 14}} = Math.handle_evaluate(infix_args)
  end

  test "handle_evaluate/1 evaluates variables and returns errors" do
    args = %{
      "ast" => %{"op" => "+", "args" => [%{"var" => "x"}, %{"num" => 1}]},
      "vars" => %{"x" => 2}
    }

    assert {:ok, %{"value" => 3}} = Math.handle_evaluate(args)
    assert {:error, {:bad_request, :missing_expression}} = Math.handle_evaluate(%{})
    assert {:error, {:parse, _, _}} = Math.handle_evaluate(%{"expr" => "1 + ("})
  end

  test "handle_evaluate/1 surfaces complexity errors" do
    {:ok, _} = Backplane.Math.Config.save(%{max_expr_nodes: 2})
    args = %{"ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}}

    assert {:error, {:complexity_limit, :max_expr_nodes, _, 2}} = Math.handle_evaluate(args)
  end

  test "handle_evaluate/1 respects the enabled flag" do
    {:ok, _} = Backplane.Math.Config.save(%{enabled: false})
    assert {:error, {:disabled, "math::evaluate"}} = Math.handle_evaluate(%{"expr" => "1 + 2"})
    {:ok, _} = Backplane.Math.Config.save(%{enabled: true})
  end
end
