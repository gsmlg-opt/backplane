defmodule Backplane.Api.Auth.DiscoveryControllerTest do
  use Backplane.Api.ConnCase, async: false

  test "publishes OIDC discovery metadata for the API issuer", %{conn: conn} do
    body =
      conn
      |> get("/.well-known/openid-configuration")
      |> json_response(200)

    assert body["issuer"] == Backplane.WebOrigins.api_base_url()
    assert body["authorization_endpoint"] == Backplane.WebOrigins.api_url("/oauth/authorize")
    assert body["token_endpoint"] == Backplane.WebOrigins.api_url("/oauth/token")
    assert body["jwks_uri"] == Backplane.WebOrigins.api_url("/oauth/jwks")
    refute "password" in body["grant_types_supported"]
    refute "implicit" in body["response_types_supported"]
    assert body["code_challenge_methods_supported"] == ["S256"]
  end
end
