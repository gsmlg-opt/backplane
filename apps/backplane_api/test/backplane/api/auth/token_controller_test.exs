defmodule Backplane.Api.Auth.TokenControllerTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Auth

  test "rejects unsupported grants", %{conn: conn} do
    body =
      conn
      |> post("/oauth/token", %{"grant_type" => "password"})
      |> json_response(400)

    assert body["error"] == "unsupported_grant_type"
  end

  test "rejects invalid confidential client credentials", %{conn: conn} do
    client = confidential_client!()

    body =
      conn
      |> put_basic_auth(client.id, "wrong-secret")
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => "missing"
      })
      |> json_response(401)

    assert body["error"] == "invalid_client"
  end

  defp confidential_client! do
    assert {:ok, _scope} =
             Auth.OAuth.create_scope(%{name: "openid", label: "openid", public: true})

    assert {:ok, %{client: client}} =
             Auth.OAuth.create_client(%{
               name: "Token Test Client",
               redirect_uris: ["https://app.example.test/auth/callback"],
               scopes: ["openid"],
               confidential: true,
               pkce: true
             })

    client
  end

  defp put_basic_auth(conn, client_id, secret) do
    credentials = Base.encode64("#{client_id}:#{secret}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end
end
