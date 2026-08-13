defmodule Backplane.Admin.MemoryOverviewLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures
  import Ecto.Query

  alias Backplane.Memory.Operations
  alias Backplane.Repo
  alias Backplane.Skills.{AgentManage, Hosts}

  setup :setup_memory_gates

  setup do
    AgentManage.clear()
    on_exit(fn -> AgentManage.clear() end)
  end

  test "renders the authoritative V2 operations instrument panel", %{conn: conn} do
    assert :ok = Operations.set_gate(:pipeline, true)
    assert :ok = Operations.set_gate(:events, true)
    assert :ok = Operations.set_gate(:dual_write, true)

    event =
      event_fixture(
        stream_id: "overview-visible-stream",
        project: "overview-project",
        status: "completed"
      )

    {:ok, view, html} = live(conn, "/memory")

    assert has_element?(view, "h1", "Memory")
    assert html =~ "Authoritative streams, committed events, and guarded V2 rollout"

    for label <- ["Pipeline", "Events", "Dual Write"] do
      assert html =~ label
    end

    assert length(Regex.scan(~r/Configured on/, html)) == 3
    assert length(Regex.scan(~r/Effective/, html)) == 3

    assert has_element?(view, "section[aria-label='Persisted activity'] dt", "Open streams")

    assert has_element?(
             view,
             "section[aria-label='Persisted activity'] dt",
             "Events persisted in 24 hours"
           )

    assert [open_streams, recent_events] =
             html
             |> Floki.parse_fragment!()
             |> Floki.find("section[aria-label='Persisted activity'] dd")
             |> Enum.map(&(Floki.text(&1) |> String.trim() |> String.to_integer()))

    assert open_streams > 0
    assert recent_events > 0

    assert html =~ "Since process start"

    assert html
           |> Floki.parse_fragment!()
           |> Floki.find("#memory-volume > div[data-bucket]")
           |> length() == 60

    assert has_element?(
             view,
             ~s(#memory-recent-events a.text-on-surface.underline[href="/memory/events/#{event.id}"]),
             event.event_type
           )

    assert has_element?(
             view,
             ~s(#memory-active-streams a.text-on-surface.underline[href="/memory/streams/#{event.stream_id}"]),
             event.stream_id
           )

    assert has_element?(view, "#memory-recent-events[phx-mounted]")
    assert has_element?(view, "#memory-active-streams[phx-mounted]")
    refute has_element?(view, "#memory-recent-events a.text-primary")
    refute has_element?(view, "#memory-active-streams a.text-primary")

    assert length(Regex.scan(~r/Unavailable/, html)) >= 5

    for region <- [
          "Ingestion health",
          "Processing health",
          "Recall health",
          "Knowledge health",
          "Coordination health"
        ] do
      assert has_element?(view, "section[aria-label='#{region}']")
    end

    assert html =~ "Sequence gaps"
    assert html =~ "Projection lag"
    assert html =~ "Embedding backlog"
    assert html =~ "Circuit breaker"
    assert html =~ "Recall p50 / p95"
    assert html =~ "FTS / vector / graph"
    assert html =~ "Estimated token reduction"
    assert html =~ "Actual LLM Proxy usage"
    assert html =~ "Channel failures"
    assert html =~ "This is an estimate, not provider usage."
    assert html =~ "/system/logs"
    assert html =~ "/memory/recall"
  end

  test "ignores unrelated setting updates without changing loaded regions", %{conn: conn} do
    event_fixture(stream_id: "overview-stable-stream")
    {:ok, view, _html} = live(conn, "/memory")
    before = render(view)

    send(view.pid, {:setting_changed, "services.day.enabled", false})

    assert Process.alive?(view.pid)
    assert render(view) == before
  end

  test "runs bounded audited repairs for an exact partition and reports the result", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory")

    for operation <-
          ~w(failed_projections reembed graph profile activity summary crystal relation lesson dead_letter) do
      assert has_element?(view, "#repair-kind option[value='#{operation}']")
    end

    params = %{
      "host_id" => "repair-host",
      "client_id" => "repair-client",
      "scope" => "private",
      "namespace" => "private",
      "kind" => "failed_projections",
      "idempotency_key" => "operator-request-1",
      "target_id" => "",
      "session_id" => "",
      "project" => "",
      "resolution" => "",
      "action" => "",
      "reason" => "",
      "date_from" => "",
      "date_to" => ""
    }

    view |> form("#memory-repair-operations form", repair: params) |> render_submit()

    assert has_element?(
             view,
             "#memory-repair-result",
             "Failed projections: dispatched; affected 0"
           )

    assert Repo.exists?(
             from(row in "memory_audit_log",
               where: row.operation == "memory.repair",
               where: fragment("?->>'host_id' = 'repair-host'", row.metadata),
               where: fragment("?->>'result' = 'dispatched'", row.metadata)
             )
           )
  end

  test "renders live content-free host capture health", %{conn: conn} do
    assert {:ok, pending_host, pending_auth_token, _token} =
             Hosts.create_agent_with_token(%{"name" => "capture-pending-host"})

    assert :ok =
             AgentManage.register_connection(pending_host, pending_auth_token, self(), %{})

    assert {:ok, host, auth_token, _token} =
             Hosts.create_agent_with_token(%{"name" => "capture-host"})

    assert :ok = AgentManage.register_connection(host, auth_token, self(), %{})

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "agent_version" => "0.1.0",
               "metadata" => %{"otp_release" => "28"},
               "capture" => %{
                 "connection_state" => "connected",
                 "spool_depth" => 2,
                 "spool_bytes" => 4_096,
                 "oldest_event_age_ms" => 12_000,
                 "captured_count" => 9,
                 "redacted_count" => 3,
                 "rejected_count" => 1,
                 "retry_count" => 1,
                 "dead_letter_count" => 0,
                 "upload_latency_ms" => 14,
                 "ack_latency_ms" => 8
               }
             })

    {:ok, view, html} = live(conn, "/memory")

    assert has_element?(view, "#memory-host-capture-#{pending_host.id}", "capture-pending-host")
    assert has_element?(view, "#memory-host-capture-#{pending_host.id}", "Unavailable")
    assert has_element?(view, "section[aria-label='Host capture']", "capture-host")
    assert has_element?(view, "#memory-host-capture-#{host.id}", "Connected")
    assert html =~ "4.0 KiB"
    assert html =~ "12s"
    assert html =~ "14 ms / 8 ms"
    assert html =~ "0.1.0"
    assert html =~ "Last heartbeat"
    refute html =~ "payload"

    assert :ok =
             AgentManage.record_sync(host.id, %{
               "status" => "failed",
               "error" => "capture uploader unavailable token=super-secret"
             })

    assert has_element?(view, "#memory-host-capture-#{host.id}", "capture uploader unavailable")
    assert has_element?(view, "#memory-host-capture-#{host.id}", "[REDACTED]")
    refute render(view) =~ "super-secret"

    assert has_element?(
             view,
             ~s(#memory-host-capture-#{host.id} a[href="/system/host-agents/#{host.id}"]),
             "Inspect"
           )

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "capture" => %{
                 "connection_state" => "disconnected",
                 "spool_depth" => 3
               }
             })

    assert has_element?(view, "#memory-host-capture-#{host.id}", "Disconnected")
    assert has_element?(view, "#memory-host-capture-#{host.id}", "3")

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "capture" => %{"connection_state" => "connected"}
             })

    assert has_element?(view, "#memory-host-capture-#{host.id}", "Connected")

    assert :ok = AgentManage.record_sync(host.id, %{"status" => "synced"})

    assert :ok =
             AgentManage.update_runtime(host.id, %{
               "capture" => %{
                 "connection_state" => "disconnected",
                 "spool_depth" => nil,
                 "spool_bytes" => nil,
                 "oldest_event_age_ms" => nil,
                 "age_warning" => nil,
                 "captured_count" => nil,
                 "redacted_count" => nil,
                 "rejected_count" => nil,
                 "retry_count" => nil,
                 "dead_letter_count" => nil,
                 "upload_latency_ms" => nil,
                 "ack_latency_ms" => nil
               }
             })

    assert has_element?(view, "#memory-host-capture-#{host.id}", "Capture telemetry unavailable")
    assert has_element?(view, "#memory-host-capture-#{host.id}", "Unavailable")

    assert :ok = AgentManage.disconnect(host.id)
    assert has_element?(view, "#memory-host-capture-#{host.id}", "Disconnected")
  end

  test "one failed tagged region does not suppress healthy content" do
    html =
      render_component(
        &Backplane.Admin.MemoryOverviewLiveTest.RegionHarness.render/1,
        %{}
      )

    assert html =~ "Persisted counts unavailable"
    assert html =~ "Memory data is unavailable"
    assert html =~ "Healthy region content"
    refute html =~ "database password leaked"
  end

  defmodule RegionHarness do
    use Backplane.Admin, :html

    import Backplane.Admin.MemoryComponents

    def render(assigns) do
      ~H"""
      <div>
        <.memory_region
          title="Persisted counts unavailable"
          result={{:error, "database password leaked"}}
        >
          Suppressed content
        </.memory_region>
        <.memory_region title="Healthy region" result={{:ok, :healthy}}>
          Healthy region content
        </.memory_region>
      </div>
      """
    end
  end
end
