defmodule Backplane.Admin.LogsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.ObservabilityCase

  import Ecto.Query

  alias Backplane.Audit
  alias Backplane.Clients
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
    refute has_element?(view, "nav.mb-6")

    Backplane.PubSubBroadcaster.broadcast_tools_call(:dispatched, %{tool: "baseline::tool"})
    html = render(view)
    assert html =~ "baseline::tool"
    assert html =~ "dispatched"
  end

  test "llm detail page uses LogQuery record", %{conn: conn} do
    {:ok, client} =
      Clients.create_client(%{
        name: "LLM log detail client #{System.unique_integer([:positive])}",
        token: "llm-log-detail-token",
        scopes: ["llm::invoke"]
      })

    log =
      insert_llm_log(%{
        client_id: client.id,
        requested_model: "fast",
        resolved_model: "MiniMax-M3",
        provider_name: "minimax",
        outcome: "success",
        input_tokens: 28_885,
        output_tokens: 95,
        total_tokens: 28_980,
        cached_tokens: 4_992,
        error_reason: "token=super-secret"
      })

    filters =
      Backplane.Admin.LogsComponents.parse_llm_filters(%{
        "model" => "fast",
        "since" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -86_400, :second)),
        "until" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 86_400, :second))
      })

    assert length(Backplane.LLM.LogQuery.list(filters)) >= 1

    {:ok, _view, detail} = live_with_sandbox(conn, "/system/logs/llm/#{log.id}")
    assert detail =~ "LLM Request Detail"
    assert detail =~ "Client"
    assert detail =~ client.name
    assert detail =~ log.request_id
    assert detail =~ "minimax/MiniMax-M3 (fast)"
    assert detail =~ "28,980 (28,885 input / 4,992 cached / 95 output)"
    assert detail =~ "Copy"
    refute detail =~ "super-secret"
  end

  test "llm list displays client first, provider, and separate formatted token counts", %{
    conn: conn
  } do
    {:ok, client} =
      Clients.create_client(%{
        name: "LLM log list client #{System.unique_integer([:positive])}",
        token: "llm-log-list-token",
        scopes: ["llm::invoke"]
      })

    insert_llm_log(%{
      client_id: client.id,
      requested_model: "fast",
      resolved_model: "MiniMax-M3",
      provider_name: "minimax",
      outcome: "success",
      input_tokens: 28_885,
      output_tokens: 95,
      total_tokens: 28_980,
      cached_tokens: 4_992
    })

    insert_llm_log(%{
      requested_model: "minimax/MiniMax-M3",
      resolved_model: "MiniMax-M3",
      provider_name: "minimax"
    })

    {:ok, _view, html} = live_with_sandbox(conn, "/system/logs/llm")

    assert html =~ "Client"
    assert html =~ client.name
    assert html =~ ~r/<th[^>]*>\s*Client\s*<\/th>.*<th[^>]*>\s*Provider\s*<\/th>/s
    assert html =~ "minimax"
    assert html =~ "minimax/MiniMax-M3 (fast)"
    refute html =~ "minimax/MiniMax-M3 (minimax/MiniMax-M3)"
    assert html =~ "Input Tokens"
    assert html =~ "Cached Tokens"
    assert html =~ "Output Tokens"
    assert html =~ ">28,885<"
    assert html =~ ">4,992<"
    assert html =~ ">95<"
  end

  test "llm logs fall back to client ID when the client no longer exists", %{conn: conn} do
    missing_client_id = Ecto.UUID.generate()
    insert_llm_log(%{client_id: missing_client_id})
    insert_llm_log(%{client_id: nil})

    {:ok, _view, html} = live_with_sandbox(conn, "/system/logs/llm")

    assert html =~ missing_client_id
    assert html =~ ">-<"
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
      mcp_request_id: root.event_id,
      trace_id: "linked-trace",
      tool_name: "skill::list",
      upstream_name: "skills"
    })

    assert length(Backplane.MCP.LogQuery.list_tool_calls_for_request(root.event_id)) >= 1

    {:ok, _view, detail} = live_with_sandbox(conn, "/system/logs/mcp/#{root.id}")
    assert detail =~ "MCP Request Detail"
    assert detail =~ "Tool call timeline"
    assert detail =~ "skill::list"
    assert detail =~ "linked-req"
    refute detail =~ "super-secret"
    refute detail =~ "arguments"
  end

  test "mcp list displays client, services, method, and distinct tools", %{conn: conn} do
    client_id = Ecto.UUID.generate()
    missing_client_id = Ecto.UUID.generate()

    root =
      insert_mcp_log(%{
        client_name: "MCP Inspector",
        client_version: "2.4.0",
        client_id: client_id,
        request_id: "mcp-list-linked-request"
      })

    insert_mcp_tool_call(%{
      mcp_request_id: root.event_id,
      upstream_name: "alpha",
      tool_name: "alpha::read"
    })

    insert_mcp_tool_call(%{
      mcp_request_id: root.event_id,
      upstream_name: "zeta",
      tool_name: "zeta::list"
    })

    insert_mcp_tool_call(%{
      mcp_request_id: root.event_id,
      upstream_name: "alpha",
      tool_name: "alpha::read"
    })

    insert_mcp_tool_call(%{
      mcp_request_id: root.event_id,
      upstream_name: nil,
      tool_namespace: "managed",
      tool_name: "managed::now"
    })

    insert_mcp_log(%{client_id: missing_client_id, request_id: "mcp-list-no-provider"})
    insert_mcp_log(%{client_id: nil, request_id: "mcp-list-no-client"})

    {:ok, _view, html} = live_with_sandbox(conn, "/system/logs/mcp")

    assert html =~
             ~r/<th[^>]*>\s*Client\s*<\/th>.*<th[^>]*>\s*Provider\s*<\/th>.*<th[^>]*>\s*Method\s*<\/th>.*<th[^>]*>\s*Tool\s*<\/th>/s

    assert html =~ "MCP Inspector 2.4.0"
    assert html =~ "alpha, managed, zeta"
    assert html =~ "alpha::read, managed::now, zeta::list"
    assert html =~ missing_client_id
    assert html =~ ~r/>-<\/td>/
    assert html =~ "/system/logs/mcp/#{root.id}"
  end

  test "mcp list loads service and tool labels for subsequent pages", %{conn: conn} do
    base = DateTime.utc_now()

    for index <- 1..50 do
      insert_mcp_log(%{
        request_id: "mcp-list-page-#{index}",
        inserted_at: DateTime.add(base, -index, :second)
      })
    end

    second_page_root =
      insert_mcp_log(%{
        request_id: "mcp-list-second-page",
        inserted_at: DateTime.add(base, -51, :second)
      })

    insert_mcp_tool_call(%{
      mcp_request_id: second_page_root.event_id,
      upstream_name: "second-page-provider",
      tool_name: "second-page::tool"
    })

    {:ok, view, _html} = live_with_sandbox(conn, "/system/logs/mcp")
    html = render_click(view, "load_more")

    assert html =~ "second-page-provider"
    assert html =~ "second-page::tool"
    assert html =~ "/system/logs/mcp/#{second_page_root.id}"
  end

  test "audit page lists only admin operations, not tool and skill audit records", %{conn: conn} do
    Audit.log_tool_call_sync(%{
      tool_name: "day::now",
      status: "ok",
      arguments_hash: Audit.hash_arguments(%{"tz" => "UTC"})
    })

    Audit.log_skill_load_sync(%{
      skill_name: "test-skill",
      client_name: "test-client"
    })

    {:ok, event} = Backplane.Admin.Audit.record("client.create", "client", Ecto.UUID.generate())
    {:ok, _view, html} = live_with_sandbox(conn, "/system/logs/audit")
    assert html =~ "Audit Logs"
    assert html =~ "client.create"
    assert html =~ event.target_id
    assert html =~ "trusted_operator"
    refute html =~ "day::now"
    refute html =~ "test-skill"
    refute html =~ "Tool Calls"
    refute html =~ "Skill Loads"
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
