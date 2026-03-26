defmodule Backplane.Web.AdminAuthPlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Backplane.Web.AdminAuthPlug

  setup do
    # Clear admin credentials before each test
    Application.delete_env(:backplane, :admin_username)
    Application.delete_env(:backplane, :admin_password)

    on_exit(fn ->
      Application.delete_env(:backplane, :admin_username)
      Application.delete_env(:backplane, :admin_password)
    end)
  end

  defp call_plug(conn) do
    AdminAuthPlug.call(conn, AdminAuthPlug.init([]))
  end

  defp basic_auth_header(user, pass) do
    encoded = Base.encode64("#{user}:#{pass}")
    "Basic #{encoded}"
  end

  test "passes through when no admin credentials configured" do
    conn = conn(:get, "/admin/dashboard") |> call_plug()
    refute conn.halted
  end

  test "challenges when credentials configured but no auth header" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn = conn(:get, "/admin/dashboard") |> call_plug()
    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Backplane Admin\""]
  end

  test "passes with correct credentials" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/admin/dashboard")
      |> put_req_header("authorization", basic_auth_header("admin", "secret"))
      |> call_plug()

    refute conn.halted
  end

  test "rejects with wrong password" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/admin/dashboard")
      |> put_req_header("authorization", basic_auth_header("admin", "wrong"))
      |> call_plug()

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects with wrong username" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/admin/dashboard")
      |> put_req_header("authorization", basic_auth_header("hacker", "secret"))
      |> call_plug()

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects malformed basic auth header" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/admin/dashboard")
      |> put_req_header("authorization", "Bearer some-token")
      |> call_plug()

    assert conn.halted
    assert conn.status == 401
  end
end
