defmodule Backplane.Web.AdminAuthPlugTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Backplane.Web.AdminAuthPlug

  setup do
    previous =
      Map.new([:admin_username, :admin_password], fn key ->
        {key, Application.fetch_env(:backplane, key)}
      end)

    clear_credentials()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:backplane, key, value)
        {key, :error} -> Application.delete_env(:backplane, key)
      end)
    end)

    :ok
  end

  defp call_plug(conn) do
    AdminAuthPlug.call(conn, AdminAuthPlug.init([]))
  end

  defp basic_auth_header(user, pass) do
    encoded = Base.encode64("#{user}:#{pass}")
    "Basic #{encoded}"
  end

  defp clear_credentials do
    Application.delete_env(:backplane, :admin_username)
    Application.delete_env(:backplane, :admin_password)
  end

  defp put_credential(key, nil), do: Application.delete_env(:backplane, key)
  defp put_credential(key, value), do: Application.put_env(:backplane, key, value)

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

  test "required mode returns 503 when credentials are absent, partial, or blank" do
    for {username, password} <- [
          {nil, nil},
          {"admin", nil},
          {nil, "secret"},
          {"", "secret"},
          {"admin", ""}
        ] do
      put_credential(:admin_username, username)
      put_credential(:admin_password, password)

      conn =
        conn(:get, "/memory")
        |> AdminAuthPlug.call(AdminAuthPlug.init(required: true))

      assert conn.halted
      assert conn.status == 503
      assert conn.resp_body == "Admin authentication is not configured"
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end

  test "required mode challenges a request only after credentials are configured" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/memory")
      |> AdminAuthPlug.call(AdminAuthPlug.init(required: true))

    assert conn.halted
    assert conn.status == 401

    assert get_resp_header(conn, "www-authenticate") == [
             "Basic realm=\"Backplane Admin\""
           ]
  end

  test "required mode accepts configured credentials" do
    Application.put_env(:backplane, :admin_username, "admin")
    Application.put_env(:backplane, :admin_password, "secret")

    conn =
      conn(:get, "/memory")
      |> put_req_header("authorization", basic_auth_header("admin", "secret"))
      |> AdminAuthPlug.call(AdminAuthPlug.init(required: true))

    refute conn.halted
  end

  test "init rejects a nonboolean required option" do
    assert_raise ArgumentError, fn ->
      AdminAuthPlug.init(required: "true")
    end
  end
end
