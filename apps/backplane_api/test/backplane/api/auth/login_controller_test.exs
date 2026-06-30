defmodule Backplane.Api.Auth.LoginControllerTest do
  use Backplane.Api.ConnCase, async: false

  test "invalid credentials re-render the login form without crashing", %{conn: conn} do
    conn =
      post(conn, "/oauth/login", %{
        "email" => "missing@example.com",
        "password" => "wrong password"
      })

    body = html_response(conn, 401)
    assert body =~ "Invalid email or password"
    assert body =~ ~s(id="oauth-login-form")
  end
end
