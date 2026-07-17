defmodule Backplane.Admin.MemoryPipelineLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures

  alias Backplane.Settings

  @pipeline "memory.pipeline.enabled"
  @events "memory.events.enabled"
  @dual_write "memory.events.dual_write"

  setup :setup_memory_auth
  setup :setup_memory_gates

  test "renders only the three implemented accessible switches and five inert later stages",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/memory/pipeline")

    assert has_element?(view, "h1", "Pipeline")

    switches =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(~s([role="switch"]))

    assert length(switches) == 3

    for {id, label} <- [
          {"pipeline-gate", "Pipeline"},
          {"events-gate", "Events"},
          {"dual-write-gate", "Dual Write"}
        ] do
      assert has_element?(view, "##{id}[role=switch]")
      assert has_element?(view, "label", label)
      assert has_element?(view, "##{id}[aria-checked=false]")
      refute has_element?(view, "##{id}[checked]")
    end

    refute has_element?(view, "#pipeline-gate[disabled]")
    assert has_element?(view, "#events-gate[disabled]")
    assert has_element?(view, "#dual-write-gate[disabled]")

    for form_id <- [
          "pipeline-gate-form",
          "events-gate-form",
          "dual-write-gate-form"
        ] do
      assert has_element?(view, "##{form_id}[phx-auto-recover=ignore]")
    end

    assert html =~
             "Master gate for Memory V2. Disable Events and Dual Write before turning it off."

    assert html =~ "Requires effective Pipeline. Disable Dual Write before turning Events off."
    assert html =~ "Requires effective Events. Enabling requires confirmation."

    assert length(Regex.scan(~r/Configured off/, html)) == 3
    assert length(Regex.scan(~r/Inactive/, html)) == 3

    tree = Floki.parse_fragment!(html)
    assert length(Floki.find(tree, "#later-stages .later-stage")) == 5
    assert length(Floki.find(tree, "#later-stages el-dm-badge")) == 5
    assert length(Regex.scan(~r/Unavailable/, html)) == 5

    for label <- [
          "Window Summaries",
          "Session Summary V2",
          "Fact Extraction V2",
          "Procedure Extraction V2",
          "Recall V2"
        ] do
      assert has_element?(view, "#later-stages .later-stage", label)
    end

    refute has_element?(view, "#later-stages input")
    refute has_element?(view, "#later-stages form")
    refute has_element?(view, "#later-stages [phx-click]")
    refute has_element?(view, "#later-stages [phx-change]")

    for key <- [
          "window_summaries",
          "session_summary_v2",
          "fact_extraction_v2",
          "procedure_extraction_v2",
          "recall_v2"
        ] do
      refute has_element?(view, ~s|[name*="#{key}"]|)
    end
  end

  test "shows configured, effective, and blocked state and permits deepest-first recovery",
       %{conn: conn} do
    set_configured!(false, true, true)
    {:ok, view, html} = live(conn, "/memory/pipeline")

    refute has_element?(view, "#pipeline-gate[checked]")
    assert has_element?(view, "#events-gate[checked][aria-checked=true]")
    assert has_element?(view, "#dual-write-gate[checked][aria-checked=true]")
    assert length(Regex.scan(~r/Configured, blocked/, html)) == 2
    refute "Effective" in badge_texts(html)

    assert has_element?(view, "#pipeline-gate[disabled]")
    assert has_element?(view, "#events-gate[disabled]")
    refute has_element?(view, "#dual-write-gate[disabled]")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "dual_write", "value" => "false"}
    })

    refute has_element?(view, "#dual-write-gate[checked]")
    assert has_element?(view, "#events-gate[checked]")
    refute has_element?(view, "#events-gate[disabled]")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "events", "value" => "false"}
    })

    refute has_element?(view, "#events-gate[checked]")
    refute has_element?(view, "#pipeline-gate[checked]")
    refute has_element?(view, "#pipeline-mutation-error")
  end

  test "accepts literal booleans in dependency order and rejects parent shutdown with a child",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/pipeline")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "events", "value" => "true"}
    })

    assert has_element?(view, "#pipeline-mutation-error", "Enable Pipeline first.")
    refute has_element?(view, "#events-gate[checked]")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "pipeline", "value" => "true"}
    })

    assert has_element?(view, "#pipeline-gate[checked][aria-checked=true]")
    assert has_element?(view, "#events-gate:not([disabled])")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "events", "value" => "true"}
    })

    assert has_element?(view, "#events-gate[checked][aria-checked=true]")
    assert Enum.count(badge_texts(render(view)), &(&1 == "Effective")) == 2

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "pipeline", "value" => "false"}
    })

    assert has_element?(view, "#pipeline-mutation-error", "Disable Events first.")
    assert has_element?(view, "#pipeline-gate[checked]")
    assert has_element?(view, "#events-gate[checked]")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "events", "value" => "false"}
    })

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "pipeline", "value" => "false"}
    })

    refute has_element?(view, "#pipeline-gate[checked]")
    refute has_element?(view, "#events-gate[checked]")
    refute has_element?(view, "#pipeline-mutation-error")
  end

  test "rejects every nonliteral or unknown submitted gate without mutation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/pipeline")

    for params <- [
          %{"gate" => %{"name" => "pipeline", "value" => "TRUE"}},
          %{"gate" => %{"name" => "pipeline", "value" => "1"}},
          %{"gate" => %{"name" => "pipeline", "value" => "yes"}},
          %{"gate" => %{"name" => "future_gate", "value" => "true"}},
          %{"gate" => %{"name" => "pipeline"}},
          %{}
        ] do
      render_change(view, "set-gate", params)

      assert has_element?(
               view,
               "#pipeline-mutation-error",
               "The submitted gate value is invalid."
             )

      refute has_element?(view, "#pipeline-gate[checked]")
      refute has_element?(view, "#events-gate[checked]")
      refute has_element?(view, "#dual-write-gate[checked]")
      assert Settings.get(@pipeline) == false
      assert Settings.get(@events) == false
      assert Settings.get(@dual_write) == false
    end
  end

  test "requires confirmation only when enabling Dual Write and disables it immediately",
       %{conn: conn} do
    set_configured!(true, true, false)
    {:ok, view, _html} = live(conn, "/memory/pipeline")

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "dual_write", "value" => "true"}
    })

    assert has_element?(view, "#dual-write-confirmation")
    assert has_element?(view, "#dual-write-confirmation[phx-mounted]")

    assert has_element?(
             view,
             "#reset-dual-write-gate[type=reset][form=dual-write-gate-form][hidden]"
           )

    assert has_element?(view, "#confirm-dual-write")
    assert has_element?(view, "#cancel-dual-write")

    assert has_element?(
             view,
             "#confirm-dual-write[type=reset][form=dual-write-gate-form]"
           )

    assert has_element?(
             view,
             "#cancel-dual-write[type=reset][form=dual-write-gate-form]"
           )

    refute has_element?(view, "#dual-write-gate[checked]")
    assert Settings.get(@dual_write) == false

    view |> element("#cancel-dual-write") |> render_click()

    refute has_element?(view, "#dual-write-confirmation")
    refute has_element?(view, "#dual-write-gate[checked]")
    assert Settings.get(@dual_write) == false

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "dual_write", "value" => "true"}
    })

    view |> element("#confirm-dual-write") |> render_click()

    refute has_element?(view, "#dual-write-confirmation")
    assert has_element?(view, "#dual-write-gate[checked][aria-checked=true]")
    assert Settings.get(@dual_write) == true

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "dual_write", "value" => "false"}
    })

    refute has_element?(view, "#dual-write-confirmation")
    refute has_element?(view, "#dual-write-gate[checked]")
    assert Settings.get(@dual_write) == false
  end

  test "rejects direct Dual Write confirmation without a pending request", %{conn: conn} do
    set_configured!(true, true, false)
    {:ok, view, _html} = live(conn, "/memory/pipeline")

    render_click(view, "confirm-dual-write", %{})

    assert Process.alive?(view.pid)
    refute has_element?(view, "#dual-write-gate[checked]")
    assert Settings.get(@dual_write) == false

    assert has_element?(
             view,
             "#pipeline-mutation-error",
             "The submitted gate value is invalid."
           )
  end

  test "reloads persisted state for relevant setting messages and ignores unrelated settings", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/memory/pipeline")
    refute has_element?(view, "#pipeline-gate[checked]")

    assert :ok = Settings.set(@pipeline, true)
    send(view.pid, {:setting_changed, @pipeline, true})

    assert has_element?(view, "#pipeline-gate[checked][aria-checked=true]")

    before = render(view)
    send(view.pid, {:setting_changed, "services.day.enabled", false})

    assert Process.alive?(view.pid)
    assert render(view) == before
  end

  test "adapter failures show fixed copy and retain all persisted gate state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory/pipeline")
    refute has_element?(view, "#pipeline-gate[checked]")

    :ok = fail_memory_settings!()

    render_change(view, "set-gate", %{
      "gate" => %{"name" => "pipeline", "value" => "true"}
    })

    assert has_element?(
             view,
             "#pipeline-mutation-error",
             "The rollout setting could not be saved."
           )

    refute has_element?(view, "#pipeline-gate[checked]")
    refute has_element?(view, "#events-gate[checked]")
    refute has_element?(view, "#dual-write-gate[checked]")
    refute render(view) =~ "forced_setting_failure"

    send(
      view.pid,
      {:setting_changed, "services.day.enabled", false}
    )

    assert Process.alive?(view.pid)
  end

  defp set_configured!(pipeline, events, dual_write) do
    assert :ok = Settings.set(@pipeline, pipeline)
    assert :ok = Settings.set(@events, events)
    assert :ok = Settings.set(@dual_write, dual_write)
  end

  defp badge_texts(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("el-dm-badge")
    |> Enum.map(&(Floki.text(&1) |> String.trim()))
  end
end
