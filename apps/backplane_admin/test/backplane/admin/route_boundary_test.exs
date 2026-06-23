defmodule Backplane.Admin.RouteBoundaryTest do
  use Backplane.Admin.LiveCase, async: false

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

  test "redirects /admin to the dashboard", %{conn: conn} do
    conn = get(conn, "/admin")

    assert redirected_to(conn) == "/admin/dashboard/overview"
  end

  test "requires admin basic auth when credentials are configured", %{conn: conn} do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn = get(conn, "/admin/dashboard/overview")

    assert response(conn, 401) == "Unauthorized"

    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
             "Basic realm=\"Backplane Admin\""
           ]
  end

  test "accepts valid admin basic auth", %{conn: conn} do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", basic_auth_header("admin", "secret"))
      |> get("/admin/dashboard/overview")

    assert html_response(conn, 200) =~ "Dashboard"
  end

  test "does not serve public or API routes", %{conn: conn} do
    routes = [
      {:post, "/api/mcp"},
      {:get, "/api/v1/models"},
      {:get, "/api/anthropic/v1/messages"},
      {:get, "/api/host-agent/something"},
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

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)
end
