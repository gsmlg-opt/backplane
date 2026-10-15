defmodule Backplane.Admin.DashboardClientUsageLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.Fixtures
  import Backplane.Admin.ObservabilityCase

  test "renders LLM and MCP usage for each registered client", %{conn: conn} do
    {client, _token} = insert_client(name: "usage-client", token: "usage-client-token")

    insert_llm_log(%{
      client_id: client.id,
      requested_model: "gpt-test",
      input_tokens: 1_000,
      cached_tokens: 200,
      output_tokens: 250
    })

    mcp_log = insert_mcp_log(%{client_id: client.id, duration_ms: 40, rpc_method: "tools/call"})
    insert_mcp_tool_call(%{mcp_request_id: mcp_log.event_id, tool_name: "math::add"})

    {:ok, view, html} = live_with_sandbox(conn, "/dashboard/usage/clients")

    assert html =~ "Client Usage"
    assert html =~ "usage-client"
    assert html =~ "1,000"
    assert html =~ "250"
    assert html =~ "MCP Usage"
    assert html =~ "gpt-test"
    assert html =~ "math::add"
    refute has_element?(view, "#client-#{client.id}-models th", "Cached Tokens")

    assert has_element?(
             view,
             "#client-#{client.id}-models td",
             "1,000 / 200 (20.0%)"
           )
  end

  test "defaults missing and invalid client ranges to today for LLM and MCP usage", %{
    conn: conn
  } do
    {client, _token} = insert_client(name: "range-client", token: "range-client-token")
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00.000000])

    insert_timed_usage(client, "today", midnight)
    insert_timed_usage(client, "yesterday", DateTime.add(midnight, -1, :microsecond))
    insert_timed_usage(client, "future", DateTime.add(DateTime.utc_now(), 3_600, :second))

    {:ok, view, _html} = live_with_sandbox(conn, "/dashboard/usage/clients")

    for path <- ["/dashboard/usage/clients", "/dashboard/usage/clients?range=invalid"] do
      render_patch(view, path)

      assert has_element?(view, ~s(#client-usage-range a[aria-current="true"]), "今天")

      for {table, suffix} <- [{"models", "-model"}, {"rpc", "/method"}, {"tools", "::tool"}] do
        selector = "#client-#{client.id}-#{table}"
        assert has_element?(view, selector, "today#{suffix}")
        refute has_element?(view, selector, "yesterday#{suffix}")
        refute has_element?(view, selector, "future#{suffix}")
      end
    end

    for label <- ["今天", "昨天", "最近一周", "最近二周", "最近一月"] do
      assert has_element?(view, "#client-usage-range a", label)
    end

    refute has_element?(view, ~s(input[name="since"]))
    refute has_element?(view, ~s(input[name="until"]))
  end

  test "client presets apply complete UTC days to LLM models, MCP requests and tools", %{
    conn: conn
  } do
    {client, _token} = insert_client(name: "preset-client", token: "preset-client-token")
    today = Date.utc_today()
    midnight = DateTime.new!(today, ~T[00:00:00.000000])
    offsets = [0, 1, 7, 8, 14, 15, 30, 31]

    for offset <- offsets do
      timestamp = DateTime.new!(Date.add(today, -offset), ~T[00:00:00.000000])
      insert_timed_usage(client, "day-#{offset}", timestamp)
    end

    for days <- [1, 7, 14, 30] do
      timestamp =
        today
        |> Date.add(-days)
        |> DateTime.new!(~T[00:00:00.000000])
        |> DateTime.add(-1, :microsecond)

      insert_timed_usage(client, "before-#{days}-day-boundary", timestamp)
    end

    insert_timed_usage(
      client,
      "last-complete-microsecond",
      DateTime.add(midnight, -1, :microsecond)
    )

    {:ok, view, _html} = live_with_sandbox(conn, "/dashboard/usage/clients")

    for {range, days, label} <- [
          {"yesterday", 1, "昨天"},
          {"week", 7, "最近一周"},
          {"fortnight", 14, "最近二周"},
          {"month", 30, "最近一月"}
        ] do
      path = "/dashboard/usage/clients?range=#{range}"
      view |> element(~s(#client-usage-range a[href="#{path}"])) |> render_click()
      assert_patch(view, path)

      assert has_element?(view, ~s(#client-usage-range a[aria-current="true"]), label)

      for {table, suffix} <- [{"models", "-model"}, {"rpc", "/method"}, {"tools", "::tool"}] do
        selector = "#client-#{client.id}-#{table}"
        assert has_element?(view, selector, "last-complete-microsecond#{suffix}")
        refute has_element?(view, selector, "before-#{days}-day-boundary#{suffix}")

        for offset <- offsets do
          if offset > 0 and offset <= days do
            assert has_element?(view, selector, "day-#{offset}#{suffix}")
          else
            refute has_element?(view, selector, "day-#{offset}#{suffix}")
          end
        end
      end
    end

    path = "/dashboard/usage/clients?range=today"
    view |> element(~s(#client-usage-range a[href="#{path}"])) |> render_click()
    assert_patch(view, path)

    assert has_element?(view, ~s(#client-usage-range a[aria-current="true"]), "今天")

    for {table, suffix} <- [{"models", "-model"}, {"rpc", "/method"}, {"tools", "::tool"}] do
      selector = "#client-#{client.id}-#{table}"
      assert has_element?(view, selector, "day-0#{suffix}")
      refute has_element?(view, selector, "last-complete-microsecond#{suffix}")
    end
  end

  defp insert_timed_usage(client, marker, inserted_at) do
    insert_llm_log(%{
      client_id: client.id,
      requested_model: "#{marker}-model",
      input_tokens: 100,
      output_tokens: 50,
      inserted_at: inserted_at
    })

    mcp_log =
      insert_mcp_log(%{
        client_id: client.id,
        rpc_method: "#{marker}/method",
        inserted_at: inserted_at
      })

    insert_mcp_tool_call(%{
      mcp_request_id: mcp_log.event_id,
      tool_name: "#{marker}::tool",
      inserted_at: inserted_at
    })
  end
end
