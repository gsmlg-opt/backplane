defmodule Backplane.Api.Auth.AuthorizeControllerTest do
  use Backplane.Api.ConnCase, async: false

  alias Backplane.Auth

  test "redirects an unauthenticated valid authorization request to login", %{conn: conn} do
    client = public_client!()

    conn =
      get(conn, "/oauth/authorize", authorize_params(client, %{"code_challenge" => "challenge"}))

    assert redirected_to(conn, 302) == "/oauth/login"
  end

  test "rejects plain PKCE", %{conn: conn} do
    client = public_client!()

    conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{
          "code_challenge" => "challenge",
          "code_challenge_method" => "plain"
        })
      )

    assert response(conn, 400) == "unsupported_code_challenge_method"
  end

  test "rejects scopes not assigned to the client", %{conn: conn} do
    client = public_client!()

    conn =
      get(
        conn,
        "/oauth/authorize",
        authorize_params(client, %{"scope" => "openid admin:all", "code_challenge" => "challenge"})
      )

    assert response(conn, 400) == "invalid_scope"
  end

  defp public_client! do
    assert {:ok, _scope} =
             Auth.OAuth.create_scope(%{name: "openid", label: "openid", public: true})

    assert {:ok, client} =
             Auth.OAuth.create_client(%{
               name: "Authorize Test Client",
               redirect_uris: ["http://localhost:4555/auth/callback"],
               scopes: ["openid"],
               confidential: false,
               pkce: true
             })

    client
  end

  defp authorize_params(client, overrides) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => "http://localhost:4555/auth/callback",
        "scope" => "openid",
        "state" => "state-123",
        "code_challenge" => "challenge",
        "code_challenge_method" => "S256"
      },
      overrides
    )
  end
end
