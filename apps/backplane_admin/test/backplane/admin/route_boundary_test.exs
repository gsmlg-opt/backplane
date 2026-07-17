defmodule Backplane.Admin.RouteBoundaryTest do
  use Backplane.Admin.LiveCase, async: false

  @memory_v2_paths [
    "/memory",
    "/memory/streams",
    "/memory/events",
    "/memory/pipeline",
    "/memory/streams/missing-stream",
    "/memory/events/00000000-0000-0000-0000-000000000000"
  ]

  @memory_v2_top_paths [
    "/memory",
    "/memory/streams",
    "/memory/events",
    "/memory/pipeline"
  ]

  @legacy_memory_paths ~w(
    /memory/browse
    /memory/stats
    /memory/observations
    /memory/sessions
    /memory/graph
    /memory/actions
    /memory/audit
    /memory/config
  )

  setup do
    previous_username = Application.get_env(:backplane, :admin_username)
    previous_password = Application.get_env(:backplane, :admin_password)

    Application.delete_env(:backplane, :admin_username)
    Application.delete_env(:backplane, :admin_password)

    on_exit(fn ->
      restore_env(:admin_username, previous_username)
      restore_env(:admin_password, previous_password)
    end)
  end

  test "redirects root to the dashboard", %{conn: conn} do
    conn = get(conn, "/")

    assert redirected_to(conn) == "/dashboard/overview"
  end

  test "does not serve old admin-prefixed routes", %{conn: conn} do
    assert get(conn, "/admin") |> response(404) == "not found"
    assert get(conn, "/admin/dashboard/overview") |> response(404) == "not found"
  end

  test "requires admin basic auth when credentials are configured", %{conn: conn} do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn = get(conn, "/dashboard/overview")

    assert response(conn, 401) == "Unauthorized"

    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
             "Basic realm=\"Backplane Admin\""
           ]
  end

  test "accepts valid admin basic auth", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", basic_auth_header("admin", "secret"))
      |> get("/dashboard/overview")

    assert html_response(conn, 200) =~ "Dashboard"
  end

  test "Memory V2 fails closed without credentials", %{conn: conn} do
    assert get(conn, "/memory") |> response(503) ==
             "Admin authentication is not configured"
  end

  test "Memory V2 fails closed with absent, partial, or blank credentials", %{conn: conn} do
    for {username, password} <- [
          {nil, nil},
          {"admin", nil},
          {nil, "secret"},
          {"", "secret"},
          {"admin", ""}
        ],
        path <- @memory_v2_paths do
      put_memory_credentials(username, password)

      assert conn
             |> recycle()
             |> get(path)
             |> response(503) == "Admin authentication is not configured"
    end
  end

  test "Memory V2 challenges anonymous requests when credentials exist", %{conn: conn} do
    put_memory_credentials("admin", "secret")
    conn = get(conn, "/memory")
    assert response(conn, 401) == "Unauthorized"
  end

  test "Memory V2 challenges anonymous requests before resource lookup", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    for path <- @memory_v2_paths do
      assert conn
             |> recycle()
             |> get(path)
             |> response(401) == "Unauthorized"
    end
  end

  test "Memory V2 accepts valid basic auth", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", basic_auth_header("admin", "secret"))
      |> get("/memory")

    assert html_response(conn, 200) =~ "Memory"
  end

  test "Memory V2 top-level routes accept valid basic auth", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        basic_auth_header("admin", "secret")
      )

    for path <- @memory_v2_top_paths do
      assert conn
             |> recycle()
             |> get(path)
             |> html_response(200) =~ "Memory"
    end
  end

  test "Memory sidebar contains only the four V2 destinations", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        basic_auth_header("admin", "secret")
      )

    {:ok, _view, html} = live(conn, "/memory")

    items =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(~s(nav[aria-label="Memory navigation"] a.admin-sidebar-link))
      |> Enum.map(fn link ->
        {
          link |> Floki.text() |> String.trim(),
          link |> Floki.attribute("href") |> List.first()
        }
      end)

    assert items == [
             {"Overview", "/memory"},
             {"Streams", "/memory/streams"},
             {"Events", "/memory/events"},
             {"Pipeline", "/memory/pipeline"}
           ]
  end

  test "Memory V2 pages accept client theme changes without disconnecting", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        basic_auth_header("admin", "secret")
      )

    for path <- @memory_v2_top_paths do
      {:ok, view, _html} = live(recycle(conn), path)

      refute has_element?(view, "#admin-theme-switcher[data-theme=moonlight]")
      assert render_hook(view, "theme_changed", %{"theme" => "sunshine"}) =~ "Memory"
      assert Process.alive?(view.pid)
    end
  end

  test "Memory V2 uses the theme-safe DuskMoon appbar surface", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        basic_auth_header("admin", "secret")
      )

    {:ok, view, _html} = live(conn, "/memory")

    assert has_element?(view, "header.appbar.appbar-surface-container")
    refute has_element?(view, "header.appbar-primary")
    assert has_element?(view, ~s(nav.admin-top-nav a[aria-current="page"].bg-primary-container))

    assert has_element?(
             view,
             ~s(nav.admin-top-nav a[aria-current="page"].text-on-primary-container)
           )
  end

  test "legacy Memory pages are literal not found without redirects", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        basic_auth_header("admin", "secret")
      )

    for path <- @legacy_memory_paths do
      response_conn =
        conn
        |> recycle()
        |> get(path)

      assert response(response_conn, 404) == "not found"
      assert Plug.Conn.get_resp_header(response_conn, "location") == []
    end
  end

  test "Memory V2 detail routes return literal not found after authentication", %{conn: conn} do
    put_memory_credentials("admin", "secret")

    conn =
      Plug.Conn.put_req_header(
        conn,
        "authorization",
        basic_auth_header("admin", "secret")
      )

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

    assert get(recycle(conn), "/memory") |> response(503) ==
             "Admin authentication is not configured"
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

  defp basic_auth_header(user, pass) do
    encoded = Base.encode64("#{user}:#{pass}")
    "Basic #{encoded}"
  end

  defp put_memory_credentials(username, password) do
    Application.put_env(:backplane, :admin_username, username)
    Application.put_env(:backplane, :admin_password, password)
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
