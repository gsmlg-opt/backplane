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
    assert html =~ "llama-test-model"
    assert html =~ "23,224"
    assert html =~ "1,300"
    assert html =~ "200"
    assert html =~ ~s(href="/dashboard/usage/mcp")
  end

  test "defaults missing and invalid LLM ranges to today", %{conn: conn, provider: provider} do
    now = DateTime.utc_now()
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00.000000])

    for {model, timestamp} <- [
          {"today-model", midnight},
          {"yesterday-model", DateTime.add(midnight, -1, :microsecond)},
          {"future-model", DateTime.add(now, 3_600, :second)}
        ] do
      insert_llm_log(%{
        provider_id: provider.id,
        provider_name: provider.name,
        requested_model: model,
        resolved_model: model,
        inserted_at: timestamp
      })
    end

    {:ok, view, _html} = live_with_sandbox(conn, "/dashboard/usage/llm")

    for path <- ["/dashboard/usage/llm", "/dashboard/usage/llm?range=invalid"] do
      render_patch(view, path)

      assert has_element?(view, ~s(#llm-usage-range a[aria-current="true"]), "今天")
      assert has_element?(view, "#llm-provider-model-usage-table", "today-model")
      refute has_element?(view, "#llm-provider-model-usage-table", "yesterday-model")
      refute has_element?(view, "#llm-provider-model-usage-table", "future-model")
    end

    for label <- ["今天", "昨天", "最近一周", "最近二周", "最近一月"] do
      assert has_element?(view, "#llm-usage-range a", label)
    end

    refute has_element?(view, ~s(input[name="since"]))
    refute has_element?(view, ~s(input[name="until"]))
  end

  test "preset links select complete UTC days and exclude today", %{
    conn: conn,
    provider: provider
  } do
    today = Date.utc_today()
    offsets = [0, 1, 7, 8, 14, 15, 30, 31]

    for offset <- offsets do
      model = "period-day-#{offset}-model"

      insert_llm_log(%{
        provider_id: provider.id,
        provider_name: provider.name,
        requested_model: model,
        resolved_model: model,
        inserted_at: DateTime.new!(Date.add(today, -offset), ~T[00:00:00.000000])
      })
    end

    for days <- [1, 7, 14, 30] do
      model = "before-#{days}-day-boundary-model"

      insert_llm_log(%{
        provider_id: provider.id,
        provider_name: provider.name,
        requested_model: model,
        resolved_model: model,
        inserted_at:
          today
          |> Date.add(-days)
          |> DateTime.new!(~T[00:00:00.000000])
          |> DateTime.add(-1, :microsecond)
      })
    end

    insert_llm_log(%{
      provider_id: provider.id,
      provider_name: provider.name,
      requested_model: "last-complete-microsecond-model",
      resolved_model: "last-complete-microsecond-model",
      inserted_at: today |> DateTime.new!(~T[00:00:00.000000]) |> DateTime.add(-1, :microsecond)
    })

    {:ok, view, _html} = live_with_sandbox(conn, "/dashboard/usage/llm")

    for {range, days, label} <- [
          {"yesterday", 1, "昨天"},
          {"week", 7, "最近一周"},
          {"fortnight", 14, "最近二周"},
          {"month", 30, "最近一月"}
        ] do
      path = "/dashboard/usage/llm?range=#{range}"
      view |> element(~s(#llm-usage-range a[href="#{path}"])) |> render_click()
      assert_patch(view, path)

      assert has_element?(view, ~s(#llm-usage-range a[aria-current="true"]), label)

      assert has_element?(
               view,
               "#llm-provider-model-usage-table",
               "last-complete-microsecond-model"
             )

      refute has_element?(
               view,
               "#llm-provider-model-usage-table",
               "before-#{days}-day-boundary-model"
             )

      for offset <- offsets do
        model = "period-day-#{offset}-model"

        if offset > 0 and offset <= days do
          assert has_element?(view, "#llm-provider-model-usage-table", model)
        else
          refute has_element?(view, "#llm-provider-model-usage-table", model)
        end
      end
    end

    {:ok, reloaded, _html} = live_with_sandbox(conn, "/dashboard/usage/llm?range=month")
    assert has_element?(reloaded, ~s(#llm-usage-range a[aria-current="true"]), "最近一月")
    assert has_element?(reloaded, "#llm-provider-model-usage-table", "period-day-30-model")
    refute has_element?(reloaded, "#llm-provider-model-usage-table", "period-day-0-model")
  end

  test "shows 30 daily token buckets above the summary independently of filters", %{
    conn: conn,
    provider: provider
  } do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    first_day = Date.add(today, -29)

    for {date, input, output} <- [{today, 123, 45}, {yesterday, 60, 7}, {first_day, 30, 2}] do
      insert_llm_log(%{
        provider_id: provider.id,
        provider_name: provider.name,
        requested_model: "chart-model-#{date}",
        resolved_model: "chart-model-#{date}",
        input_tokens: input,
        output_tokens: output,
        cached_tokens: 9_999,
        inserted_at: DateTime.new!(date, ~T[00:00:00.000000])
      })
    end

    {:ok, view, html} = live_with_sandbox(conn, "/dashboard/usage/llm?range=yesterday")

    assert has_element?(view, "#llm-daily-tokens", "Daily Token Usage")
    assert has_element?(view, "#llm-daily-tokens", "267")

    assert length(
             Floki.find(Floki.parse_document!(html), "#llm-daily-tokens-chart button[data-date]")
           ) ==
             30

    assert has_element?(
             view,
             ~s(button[data-date="#{today}"][data-total-tokens="168"][data-input-tokens="123"][data-cached-tokens="9999"][data-output-tokens="45"])
           )

    assert has_element?(
             view,
             ~s(button[data-date="#{Date.add(today, -2)}"][data-input-tokens="0"][data-output-tokens="0"])
           )

    assert has_element?(view, ~s(button[data-date="#{first_day}"][data-input-tokens="30"]))

    assert has_element?(
             view,
             ~s(button[data-date="#{today}"][interestfor="daily-tokens-#{today}"])
           )

    assert has_element?(view, "#daily-tokens-#{today}[popover]", "Input")
    assert has_element?(view, "#daily-tokens-#{today}[popover]", "Cached")
    assert has_element?(view, "#daily-tokens-#{today}[popover]", "Output")
    assert has_element?(view, "#daily-tokens-#{today} dd", "9,999")

    assert length(
             Floki.find(
               Floki.parse_document!(html),
               "#llm-daily-tokens-chart button[data-date] > span"
             )
           ) == 30

    assert has_element?(view, "#llm-provider-model-usage-table", "chart-model-#{yesterday}")
    refute has_element?(view, "#llm-provider-model-usage-table", "chart-model-#{today}")
    refute has_element?(view, "#llm-provider-model-usage-table", "chart-model-#{first_day}")
    [chart, summary] = Enum.map(["Daily Token Usage", "Total Requests"], &:binary.match(html, &1))
    assert elem(chart, 0) < elem(summary, 0)
  end

  test "renders an empty daily chart with zero-filled dates", %{conn: conn} do
    {:ok, view, html} = live_with_sandbox(conn, "/dashboard/usage/llm")

    assert has_element?(view, "#llm-daily-tokens", "No token usage recorded in the last 30 days.")

    assert length(
             Floki.find(Floki.parse_document!(html), "#llm-daily-tokens-chart button[data-date]")
           ) ==
             30

    refute html =~ "NaN"
    refute html =~ "Infinity"
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
      output_tokens: 5,
      inserted_at: DateTime.utc_now()
    }

    Repo.insert!(struct(UsageLog, Map.merge(defaults, attrs)))
  end
end
