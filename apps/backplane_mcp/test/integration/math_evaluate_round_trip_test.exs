defmodule Backplane.Integration.MathEvaluateRoundTripTest do
  use Backplane.ConnCase, async: false

  setup do
    Backplane.Repo.delete_all(Backplane.Math.Config.Record)
    :ok = Backplane.Math.Config.reload()
    :ok
  end

  test "tools/list includes math::evaluate" do
    resp = mcp_request("tools/list")
    tools = get_in(resp, ["result", "tools"])
    assert Enum.any?(tools, &(&1["name"] == "math::evaluate"))
  end

  test "tools/call computes JSON AST and infix expressions end-to-end" do
    json_resp =
      mcp_request("tools/call", %{
        "name" => "math::evaluate",
        "arguments" => %{
          "ast" => %{
            "op" => "*",
            "args" => [
              %{"num" => 2},
              %{"op" => "+", "args" => [%{"num" => 3}, %{"num" => 4}]}
            ]
          }
        }
      })

    refute json_resp["error"]
    assert Jason.encode!(json_resp) =~ "14"

    infix_resp =
      mcp_request("tools/call", %{
        "name" => "math::evaluate",
        "arguments" => %{"expr" => "sin(0) + 2"}
      })

    refute infix_resp["error"]
    assert Jason.encode!(infix_resp) =~ "2"
  end

  test "surfaces complexity caps and rejects code-like payloads" do
    {:ok, _} = Backplane.Math.Config.save(%{max_expr_nodes: 2})

    capped =
      mcp_request("tools/call", %{
        "name" => "math::evaluate",
        "arguments" => %{"ast" => %{"op" => "+", "args" => [%{"num" => 1}, %{"num" => 2}]}}
      })

    assert Jason.encode!(capped) =~ "complexity_limit"

    {:ok, _} = Backplane.Math.Config.save(%{max_expr_nodes: 10_000})

    rejected =
      mcp_request("tools/call", %{
        "name" => "math::evaluate",
        "arguments" => %{"expr" => "System.cmd(\"rm\", [\"-rf\", \"/\"])"}
      })

    payload = Jason.encode!(rejected)
    assert payload =~ "parse"
  end
end
