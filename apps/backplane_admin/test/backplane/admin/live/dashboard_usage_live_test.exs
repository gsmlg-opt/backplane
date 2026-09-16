defmodule Backplane.Admin.DashboardUsageLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.ObservabilityCase

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
      input_tokens: 23_124,
      output_tokens: 1_250
    })

    insert_llm_log(%{
      provider_id: provider.id,
      provider_name: provider.name,
      requested_model: "fast",
      resolved_model: "llama-test-model",
      input_tokens: 100,
      cached_tokens: 75,
      output_tokens: 50
    })

    {:ok, _view, html} = live_with_sandbox(conn, "/dashboard/usage/llm")

    assert html =~ "LLM Usage"
    assert html =~ "Total Requests"
    assert html =~ "Input Tokens"
    assert html =~ "Cached Tokens"
    assert html =~ "Output Tokens"
    assert html =~ "Alias Calls"
    assert html =~ "Average Latency"
    assert html =~ "Usage By Provider"
    assert html =~ "usage-test-provider"
    assert html =~ "23,224"
    assert html =~ "1,300"
    assert html =~ "200"
    assert html =~ ~s(href="/dashboard/usage/mcp")
  end

  test "renders MCP usage page from persisted MCP logs", %{conn: conn} do
    insert_mcp_log(%{rpc_method: "tools/list", outcome: "success"})

    {:ok, _view, html} = live_with_sandbox(conn, "/dashboard/usage/mcp")

    assert html =~ "MCP Usage"
    assert html =~ "Total MCP Requests"
    assert html =~ "tools/list"
    assert html =~ ~s(href="/dashboard/usage/llm")
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
