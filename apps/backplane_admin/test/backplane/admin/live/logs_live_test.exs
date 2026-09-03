defmodule Backplane.Admin.LogsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.ObservabilityCase

  import Ecto.Query

  alias Backplane.Audit
  alias Backplane.Memory.Workers.GraphExtractWorker
  alias Backplane.Repo

  setup do
    clear_observability_logs!()
    :ok
  end

  test "overview renders navigation and live activity panel", %{conn: conn} do
    {:ok, view, html} = live_with_sandbox(conn, "/system/logs")

    assert html =~ "Logs"
    assert html =~ "Browse LLM logs"
    assert html =~ "Browse MCP logs"
    assert html =~ "Live tool activity"

    Backplane.PubSubBroadcaster.broadcast_tools_call(:dispatched, %{tool: "baseline::tool"})
    html = render(view)
    assert html =~ "baseline::tool"
    assert html =~ "dispatched"
  end

  test "llm detail page uses LogQuery record", %{conn: conn} do
    log =
      insert_llm_log(%{
        requested_model: "admin-llm-model",
        outcome: "success",
        error_reason: "token=super-secret"
      })

    filters =
      Backplane.Admin.LogsComponents.parse_llm_filters(%{
        "model" => "admin-llm-model",
        "since" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -86_400, :second)),
        "until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 86_400, :second))
      })

    assert length(Backplane.LLM.LogQuery.list(filters)) >= 1

    {:ok, _view, detail} = live_with_sandbox(conn, "/system/logs/llm/#{log.id}")
    assert detail =~ "LLM Request Detail"
    assert detail =~ log.request_id
    assert detail =~ "Copy"
    refute detail =~ "super-secret"
  end

  test "llm list shows empty state when no records match", %{conn: conn} do
    {:ok, _view, html} = live_with_sandbox(conn, "/system/logs/llm?model=missing-model-xyz")
    assert html =~ "No LLM logs found"
  end

  test "llm keyset pagination via LogQuery", %{conn: _conn} do
    base = DateTime.utc_now()

    for index <- 1..55 do
      insert_llm_log(%{
        requested_model: "paginate-model",
        inserted_at: DateTime.add(base, -index, :second)
      })
    end

    filters = %{
      model: "paginate-model",
      since: DateTime.add(base, -86_400, :second),
      until: DateTime.add(base, 86_400, :second)
    }

    first_page = Backplane.LLM.LogQuery.list(filters, %{limit: 50})
    assert length(first_page) == 50

    last = List.last(first_page)

    second_page =
      Backplane.LLM.LogQuery.list(filters, %{
        limit: 50,
        cursor: {last.inserted_at, last.id}
      })

    assert length(second_page) == 5
  end

  test "mcp detail shows root timeline and child tool calls", %{conn: conn} do
    root =
      insert_mcp_log(%{
        rpc_method: "tools/call",
        request_id: "linked-req",
        trace_id: "linked-trace",
        error_message: "upstream token=super-secret"
      })

    insert_mcp_tool_call(%{
      mcp_request_id: "linked-req",
      trace_id: "linked-trace",
      tool_name: "skill::list",
      upstream_name: "skills"
    })

    assert length(Backplane.MCP.LogQuery.list_tool_calls_for_request("linked-req")) >= 1

    {:ok, _view, detail} = live_with_sandbox(conn, "/system/logs/mcp/#{root.id}")
    assert detail =~ "MCP Request Detail"
    assert detail =~ "Tool call timeline"
    assert detail =~ "skill::list"
    assert detail =~ "linked-req"
    refute detail =~ "super-secret"
    refute detail =~ "arguments"
  end

  test "audit page lists tool and skill audit records", %{conn: conn} do
    Audit.log_tool_call_sync(%{
      tool_name: "day::now",
      status: "ok",
      arguments_hash: Audit.hash_arguments(%{"tz" => "UTC"})
    })

    Audit.log_skill_load_sync(%{
      skill_name: "test-skill",
      client_name: "test-client"
    })

    {:ok, view, html} = live_with_sandbox(conn, "/system/logs/audit")
    assert html =~ "Audit Logs"
    assert html =~ "day::now"

    html = view |> element("el-dm-button", "Skill Loads") |> render_click()
    assert html =~ "test-skill"
  end

  test "jobs page preserves failed job detail with sanitized error", %{conn: conn} do
    job =
      GraphExtractWorker.new(%{"memory_id" => Ecto.UUID.generate()})
      |> Repo.insert!()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [
        state: "discarded",
        attempted_at: DateTime.utc_now(),
        errors: [
          %{
            "attempt" => 1,
            "at" => DateTime.to_iso8601(DateTime.utc_now()),
            "error" => "upload failed token=super-secret"
          }
        ]
      ]
    )

    {:ok, view, html} = live_with_sandbox(conn, "/system/logs/jobs?job_id=#{job.id}")

    assert has_element?(view, "#job-detail-#{job.id}", "GraphExtractWorker")
    assert html =~ "upload failed"
    assert html =~ "[REDACTED]"
    refute html =~ "super-secret"
  end

  test "sinks page renders writer health sections", %{conn: conn} do
    {:ok, _view, html} = live_with_sandbox(conn, "/system/logs/sinks")
    assert html =~ "Observability Sinks"
    assert html =~ "LLM LogWriter"
    assert html =~ "MCP LogWriter"
    assert html =~ "Feature flags"
  end

  test "logs routes respond for all sections", %{conn: conn} do
    for path <- [
          "/system/logs",
          "/system/logs/llm",
          "/system/logs/mcp",
          "/system/logs/audit",
          "/system/logs/jobs",
          "/system/logs/sinks"
        ] do
      assert {:ok, _view, _html} = live_with_sandbox(conn, path)
    end
  end
end
