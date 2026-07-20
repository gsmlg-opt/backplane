defmodule Backplane.Admin.MemoryOverviewLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Backplane.Admin.MemoryFixtures

  alias Backplane.Memory.Operations

  setup :setup_memory_gates

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

    assert length(
             html
             |> Floki.parse_fragment!()
             |> Floki.find("section[aria-label='Persisted activity'] dd")
             |> Enum.filter(&(Floki.text(&1) |> String.trim() == "1"))
           ) == 2

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

    assert length(Regex.scan(~r/Unavailable/, html)) == 5

    refute html =~ "Active Memories"
    refute html =~ "Graph Nodes"
    refute html =~ "Memory by Type"
  end

  test "ignores unrelated setting updates without changing loaded regions", %{conn: conn} do
    event_fixture(stream_id: "overview-stable-stream")
    {:ok, view, _html} = live(conn, "/memory")
    before = render(view)

    send(view.pid, {:setting_changed, "services.day.enabled", false})

    assert Process.alive?(view.pid)
    assert render(view) == before
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
