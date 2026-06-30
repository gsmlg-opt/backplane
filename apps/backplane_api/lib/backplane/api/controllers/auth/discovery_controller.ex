defmodule Backplane.Api.Auth.DiscoveryController do
  use Backplane.Api, :controller

  alias Backplane.WebOrigins

  def show(conn, _params) do
    issuer = WebOrigins.api_base_url()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: WebOrigins.api_url("/oauth/authorize"),
      token_endpoint: WebOrigins.api_url("/oauth/token"),
      jwks_uri: WebOrigins.api_url("/oauth/jwks"),
      userinfo_endpoint: WebOrigins.api_url("/oauth/userinfo"),
      introspection_endpoint: WebOrigins.api_url("/oauth/introspect"),
      revocation_endpoint: WebOrigins.api_url("/oauth/revoke"),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post", "none"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"]
    })
  end
end
