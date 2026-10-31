defmodule Backplane.Admin.RouteBoundaryTest do
  use Backplane.Admin.LiveCase, async: false

  @memory_top_paths [
    "/memory",
    "/memory/search",
    "/memory/streams",
    "/memory/events",
    "/memory/sessions",
    "/memory/timeline",
    "/memory/memories",
    "/memory/graph",
    "/memory/profile",
    "/memory/actions",
    "/memory/audit",
    "/memory/config",
    "/memory/pipeline",
    "/memory/activity",
    "/memory/replay",
    "/memory/lessons",
    "/memory/crystals",
    "/memory/recall"
  ]

  @legacy_memory_paths ~w(
    /memory/browse
    /memory/stats
    /memory/observations
  )

  test "redirects root to the dashboard", %{conn: conn} do
    conn = get(conn, "/")

    assert redirected_to(conn) == "/dashboard/overview"
  end

  test "does not serve old admin-prefixed routes", %{conn: conn} do
    assert get(conn, "/admin") |> response(404) == "not found"
    assert get(conn, "/admin/dashboard/overview") |> response(404) == "not found"
  end

  test "admin pages do not require authentication when legacy credentials are configured",
       %{conn: conn} do
    previous_username = Application.get_env(:backplane, :admin_username)
    previous_password = Application.get_env(:backplane, :admin_password)

    on_exit(fn ->
      restore_env(:admin_username, previous_username)
      restore_env(:admin_password, previous_password)
    end)

    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    assert get(conn, "/dashboard/overview") |> html_response(200) =~ "Dashboard"
    assert get(recycle(conn), "/memory") |> html_response(200) =~ "Memory"
  end

  test "Memory top-level routes are accessible without authentication", %{conn: conn} do
    for path <- @memory_top_paths do
      assert conn
             |> recycle()
             |> get(path)
             |> html_response(200) =~ "Memory"
    end
  end

  test "Memory sidebar matches the required Observe, Knowledge, Coordinate, and Operate IA", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/memory")

    expected_items = [
      {"Overview", "/memory"},
      {"Activity", "/memory/activity"},
      {"Sessions", "/memory/sessions"},
      {"Timeline", "/memory/timeline"},
      {"Replay", "/memory/replay"},
      {"Memories", "/memory/memories"},
      {"Lessons", "/memory/lessons"},
      {"Crystals", "/memory/crystals"},
      {"Graph", "/memory/graph"},
      {"Profile", "/memory/profile"},
      {"Actions", "/memory/actions"},
      {"Search", "/memory/search"},
      {"Pipeline", "/memory/pipeline"},
      {"Recall Inspector", "/memory/recall"},
      {"Audit", "/memory/audit"},
      {"Config", "/memory/config"}
    ]

    document = Floki.parse_fragment!(html)

    desktop_items =
      document
      |> Floki.find("#admin-sidebar a[aria-label]")
      |> Enum.map(fn link ->
        {
          link |> Floki.attribute("aria-label") |> List.first(),
          link |> Floki.attribute("href") |> List.first()
        }
      end)

    mobile_items =
      document
      |> Floki.find("#memory-mobile-navigation nav a")
      |> Enum.map(fn link ->
        {
          link |> Floki.text() |> String.trim(),
          link |> Floki.attribute("href") |> List.first()
        }
      end)

    assert desktop_items == expected_items
    assert mobile_items == expected_items

    assert has_element?(
             view,
             ~s(#admin-sidebar[aria-label="Memory navigation"])
           )

    assert has_element?(
             view,
             ~s(#admin-sidebar [data-left-menu-toggle][aria-controls="admin-sidebar-scroll"][aria-expanded="true"])
           )

    assert has_element?(view, "#admin-sidebar-scroll")
    assert has_element?(view, ~s(#admin-sidebar a[href="/memory"][aria-current="page"]))

    for group <- ~w(Observe Knowledge Coordinate Operate) do
      id = String.downcase(group)

      assert has_element?(view, "#admin-sidebar-group-#{id} > summary", group)
      assert has_element?(view, "#memory-mobile-navigation .memory-eyebrow", group)
    end

    assert has_element?(
             view,
             ~s(#admin-sidebar-group-operate a[href="/memory/search"]),
             "Search"
           )

    {:ok, search, _html} = live(recycle(conn), "/memory/search")

    assert has_element?(search, ~s(#admin-sidebar a[href="/memory/search"][aria-current="page"]))
    refute has_element?(search, ~s(#admin-sidebar a[href="/memory"][aria-current="page"]))

    assert has_element?(
             search,
             ~s(#admin-sidebar-navigation[data-active-nav="memory-search"])
           )
  end

  test "mobile Memory navigation preserves the same source selection as desktop", %{conn: conn} do
    query = %{"host" => "navigation-host", "repository" => "navigation-repo"}
    {:ok, view, html} = live(conn, "/memory/search?" <> URI.encode_query(query))
    document = Floki.parse_fragment!(html)

    desktop_paths = Floki.attribute(document, "#admin-sidebar a[aria-label]", "href")
    mobile_paths = Floki.attribute(document, "#memory-mobile-navigation nav a", "href")
    assert mobile_paths == desktop_paths
    assert Enum.all?(mobile_paths, &(URI.decode_query(URI.parse(&1).query) == query))
    assert has_element?(view, "#memory-mobile-navigation summary", "Search")
    refute has_element?(view, "#memory-mobile-navigation[open]")
    assert has_element?(view, ~s(#memory-mobile-navigation a[aria-current="page"]), "Search")
  end

  test "Memory pages accept client theme changes without disconnecting", %{conn: conn} do
    for path <- @memory_top_paths do
      {:ok, view, _html} = live(recycle(conn), path)

      refute has_element?(view, "#admin-theme-switcher[data-theme=moonlight]")
      assert render_hook(view, "theme_changed", %{"theme" => "sunshine"}) =~ "Memory"
      assert Process.alive?(view.pid)
    end
  end

  test "System sidebar keeps Monitor and Logs as sibling groups", %{conn: conn} do
    {:ok, view, html} = live(conn, "/system/monitor/plans")

    groups =
      html
      |> Floki.parse_fragment!()
      |> Floki.find("#admin-sidebar-group-monitor, #admin-sidebar-group-log")
      |> Enum.map(fn group ->
        {
          group |> Floki.find("summary") |> Floki.text() |> String.trim(),
          group
          |> Floki.find("a[aria-label]")
          |> Enum.map(fn link ->
            {link |> Floki.attribute("aria-label") |> List.first(),
             link |> Floki.attribute("href") |> List.first()}
          end)
        }
      end)

    expected_groups = [
      {"Monitor",
       [
         {"Plan Usage", "/system/monitor/plans"},
         {"API Usage", "/system/monitor/api-usage"}
       ]},
      {"Log",
       [
         {"LLM Log", "/system/logs/llm"},
         {"MCP Log", "/system/logs/mcp"},
         {"Audit Log", "/system/logs/audit"},
         {"Job", "/system/logs/jobs"},
         {"Sink", "/system/logs/sinks"}
       ]}
    ]

    assert groups == expected_groups

    mobile_groups =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(~s(nav[aria-label="System navigation"] .admin-sidebar-group))
      |> Enum.map(fn group ->
        {
          group |> Floki.find(".admin-sidebar-group-title") |> Floki.text() |> String.trim(),
          group
          |> Floki.find("a.admin-sidebar-link")
          |> Enum.map(fn link ->
            {link |> Floki.text() |> String.trim(),
             link |> Floki.attribute("href") |> List.first()}
          end)
        }
      end)

    assert mobile_groups == expected_groups

    refute has_element?(view, "#admin-sidebar-group-monitor #admin-sidebar-group-log")
    refute has_element?(view, "#admin-sidebar-group-log #admin-sidebar-group-monitor")

    refute has_element?(view, ~s(a[href="/system/logs"]), "Logs")
  end

  test "same-section links keep the sidebar configuration and publish the destination route", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/system/appearance")

    assert [sidebar] =
             Enum.filter(live_children(view), fn child ->
               String.starts_with?(child.id, "admin-sidebar-live-")
             end)

    assert has_element?(
             view,
             ~s(#admin-sidebar a[href="/system/config"][data-phx-link="redirect"])
           )

    assert has_element?(
             view,
             ~s(#admin-sidebar-navigation[data-active-nav="system-appearance"])
           )

    # LiveViewTest follows navigation by mounting a new client, so process
    # continuity for sticky children is verified in the browser.
    {:ok, next_view, _html} =
      view
      |> element(~s(#admin-sidebar a[href="/system/config"]))
      |> render_click()
      |> follow_redirect(conn, "/system/config")

    assert [next_sidebar] =
             Enum.filter(live_children(next_view), fn child ->
               String.starts_with?(child.id, "admin-sidebar-live-")
             end)

    assert next_sidebar.id == sidebar.id

    assert has_element?(
             next_view,
             ~s(#admin-sidebar a[href="/system/config"][aria-current="page"])
           )

    assert has_element?(
             next_view,
             ~s(#admin-sidebar-navigation[data-active-nav="system-config"])
           )
  end

  test "Memory V2 uses the DuskMoon primary appbar background", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/memory")

    assert has_element?(view, "header.appbar.appbar-primary")
    refute has_element?(view, "header.appbar-surface-container")
    assert has_element?(view, ~s(nav.admin-top-nav a[aria-current="page"].bg-primary-container))

    assert has_element?(
             view,
             ~s(nav.admin-top-nav a[aria-current="page"].text-on-primary-container)
           )
  end

  test "legacy Memory pages are literal not found without redirects", %{conn: conn} do
    for path <- @legacy_memory_paths do
      response_conn =
        conn
        |> recycle()
        |> get(path)

      assert response(response_conn, 404) == "not found"
      assert Plug.Conn.get_resp_header(response_conn, "location") == []
    end
  end

  test "Memory V2 detail routes return literal not found", %{conn: conn} do
    for path <- [
          "/memory/streams/missing-stream",
          "/memory/events/#{Ecto.UUID.generate()}",
          "/memory/events/not-a-uuid"
        ] do
      assert conn
             |> recycle()
             |> get(path)
             |> response(404) == "not found"
    end
  end

  test "entering Memory crosses the LiveView session boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard/overview")

    assert has_element?(view, ~s(a[href="/memory"][data-phx-link="redirect"]))

    assert {:error, {:redirect, %{to: redirect_to}}} =
             live_redirect(view, to: "/memory")

    assert URI.parse(redirect_to).path == "/memory"

    assert get(recycle(conn), "/memory") |> html_response(200) =~ "Memory"
  end

  test "does not serve public or API routes", %{conn: conn} do
    routes = [
      {:post, "/mcp"},
      {:get, "/v1/models"},
      {:get, "/v1/messages"},
      {:get, "/host-agent/something"},
      {:get, "/host-agent/socket"}
    ]

    for {method, path} <- routes do
      conn = dispatch(conn, method, path)

      assert response(conn, 404) == "not found"
    end
  end

  defp dispatch(conn, :get, path), do: get(recycle(conn), path)
  defp dispatch(conn, :post, path), do: post(recycle(conn), path, %{})

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
