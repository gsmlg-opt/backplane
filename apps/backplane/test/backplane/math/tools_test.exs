defmodule Backplane.Math.ToolsTest do
  use Backplane.DataCase, async: false

  alias Backplane.Math.Tools

  setup do
    Backplane.Repo.delete_all(Backplane.Math.Config.Record)
    :ok = Backplane.Math.Config.reload()
    :ok
  end

  test "tools/0 emits math::evaluate with ToolModule-shaped fields" do
    [tool] = Tools.tools()
    assert tool.name == "math::evaluate"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert tool.module == Tools
    assert tool.handler == :evaluate
  end

  test "call/1 evaluates JSON AST and infix expressions" do
    json_args = %{"_handler" => "evaluate", "ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}}
    assert {:ok, %{"value" => 3, "ast" => %{"num" => 3}, "latex" => "3", "text" => "3"}} = Tools.call(json_args)

    infix_args = %{"_handler" => "evaluate", "expr" => "2 * (3 + 4)"}
    assert {:ok, %{"value" => 14}} = Tools.call(infix_args)
  end

  test "call/1 evaluates variables and returns errors" do
    args = %{
      "_handler" => "evaluate",
      "ast" => %{"op" => "+", "args" => [%{"var" => "x"}, %{"num" => 1}]},
      "vars" => %{"x" => 2}
    }

    assert {:ok, %{"value" => 3}} = Tools.call(args)
    assert {:error, {:bad_request, :missing_expression}} = Tools.call(%{"_handler" => "evaluate"})
    assert {:error, {:parse, _, _}} = Tools.call(%{"_handler" => "evaluate", "expr" => "1 + ("})
  end

  test "call/1 surfaces complexity errors" do
    {:ok, _} = Backplane.Math.Config.save(%{max_expr_nodes: 2})
    args = %{"_handler" => "evaluate", "ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}}

    assert {:error, {:complexity_limit, :max_expr_nodes, _, 2}} = Tools.call(args)
  end
end
