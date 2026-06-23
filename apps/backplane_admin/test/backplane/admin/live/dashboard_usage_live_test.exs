defmodule Backplane.Admin.DashboardUsageLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.LLM.{Provider, UsageLog}
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  setup do
    Credentials.store("usage-test-cred", "sk-test", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "usage-test-provider",
        credential: "usage-test-cred"
      })

    {:ok, provider: provider}
  end

  test "renders LLM usage page from persisted usage logs", %{conn: conn, provider: provider} do
    insert_usage(provider.id, %{
      model: "llama-test-model",
      status: 200,
      latency_ms: 150,
      input_tokens: 100,
      output_tokens: 50
    })

    {:ok, _view, html} = live(conn, "/admin/dashboard/usage/llm")

    assert html =~ "LLM Usage"
    assert html =~ "Total Requests"
    assert html =~ "Input Tokens"
    assert html =~ "Output Tokens"
    assert html =~ "Average Latency"
    assert html =~ "llama-test-model"
    assert html =~ "200"
    assert html =~ ~s(href="/admin/dashboard/usage/mcp")
  end

  test "renders MCP usage page from runtime metrics", %{conn: conn} do
    :telemetry.execute([:backplane, :mcp_request, :start], %{}, %{method: "tools/list"})

    {:ok, _view, html} = live(conn, "/admin/dashboard/usage/mcp")

    assert html =~ "MCP Usage"
    assert html =~ "Total MCP Requests"
    assert html =~ "tools/list"
    assert html =~ ~s(href="/admin/dashboard/usage/llm")
  end

  defp insert_usage(provider_id, attrs) do
    defaults = %{
      provider_id: provider_id,
      model: "llama-test-model",
      status: 200,
      latency_ms: 100,
      input_tokens: 10,
      output_tokens: 5
    }

    Repo.insert!(struct(UsageLog, Map.merge(defaults, attrs)))
  end
end
