defmodule Backplane.Api.Auth.OAuthE2ETest do
  use Backplane.Api.ConnCase, async: false

  import Backplane.Auth.Fixtures

  @redirect_uri "https://gsmlg-app-backend.example.test/auth/callback"
  @issuer "http://localhost:4002"
  @password "correct horse battery staple"

  test "first-party app completes authorization code PKCE OIDC flow through the public API",
       %{conn: conn} do
    discovery =
      conn
      |> get("/.well-known/openid-configuration")
      |> json_response(200)

    assert discovery["issuer"] == @issuer
    assert discovery["authorization_endpoint"] == "#{@issuer}/oauth/authorize"
    assert discovery["token_endpoint"] == "#{@issuer}/oauth/token"
    assert discovery["jwks_uri"] == "#{@issuer}/oauth/jwks"
    assert discovery["userinfo_endpoint"] == "#{@issuer}/oauth/userinfo"
    assert discovery["introspection_endpoint"] == "#{@issuer}/oauth/introspect"
    assert discovery["revocation_endpoint"] == "#{@issuer}/oauth/revoke"

    user = auth_user_fixture!(email: "alice@example.com", name: "Alice", password: @password)

    client =
      oauth_client_fixture!(
        name: "GSMLG App Backend",
        redirect_uris: [@redirect_uri],
        scopes: ["openid", "profile", "email", "gsmlg:read"],
        confidential: true,
        pkce: true
      )

    verifier = "a-very-long-pkce-verifier-for-the-gsmlg-app-backend-client"
    state = "state-#{System.unique_integer([:positive])}"
    nonce = "nonce-#{System.unique_integer([:positive])}"

    authorize_conn =
      conn
      |> recycle()
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "scope" => "openid profile email gsmlg:read",
        "state" => state,
        "nonce" => nonce,
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256"
      })

    login_location = redirected_to(authorize_conn, 302)
    assert URI.parse(login_location).path == "/oauth/login"

    login_conn =
      authorize_conn
      |> recycle()
      |> get(path_with_query(login_location))

    login_params =
      login_conn
      |> html_response(200)
      |> form_inputs("#oauth-login-form")
      |> Map.merge(%{"email" => user.email, "password" => @password})

    callback_conn =
      login_conn
      |> recycle()
      |> post("/oauth/login", login_params)

    callback_uri = callback_conn |> redirected_to(302) |> URI.parse()
    assert "#{callback_uri.scheme}://#{callback_uri.host}#{callback_uri.path}" == @redirect_uri

    callback_params = URI.decode_query(callback_uri.query || "")
    assert callback_params["state"] == state
    assert is_binary(callback_params["code"])
    refute callback_params["error"]

    token_conn =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => callback_params["code"],
        "redirect_uri" => @redirect_uri,
        "code_verifier" => verifier
      })

    token_response = json_response(token_conn, 200)
    assert token_response["token_type"] == "Bearer"
    assert is_integer(token_response["expires_in"])
    assert scope_includes?(token_response["scope"], "openid")
    assert scope_includes?(token_response["scope"], "gsmlg:read")

    access_token = fetch_string!(token_response, "access_token")
    refresh_token = fetch_string!(token_response, "refresh_token")
    id_token = fetch_string!(token_response, "id_token")

    jwks_response =
      conn
      |> recycle()
      |> get("/oauth/jwks")
      |> json_response(200)

    access_claims = verify_jwt_with_jwks!(access_token, jwks_response)
    assert access_claims["iss"] == @issuer
    assert access_claims["sub"] == user.id
    assert access_claims["client_id"] == client.id
    assert scope_includes?(access_claims["scope"], "gsmlg:read")

    id_claims = verify_jwt_with_jwks!(id_token, jwks_response)
    assert id_claims["iss"] == @issuer
    assert id_claims["sub"] == user.id
    assert id_claims["aud"] == client.id
    assert id_claims["nonce"] == nonce
    assert id_claims["email"] == "alice@example.com"

    userinfo =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> get("/oauth/userinfo")
      |> json_response(200)

    assert userinfo["sub"] == user.id
    assert userinfo["email"] == "alice@example.com"
    assert userinfo["name"] == "Alice"

    introspection =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/introspect", %{"token" => access_token})
      |> json_response(200)

    assert introspection["active"] == true
    assert introspection["sub"] == user.id
    assert introspection["client_id"] == client.id
    assert scope_includes?(introspection["scope"], "gsmlg:read")

    refreshed =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      })
      |> json_response(200)

    assert fetch_string!(refreshed, "access_token") != access_token
    assert fetch_string!(refreshed, "refresh_token") != refresh_token

    revoke_conn =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/revoke", %{
        "token" => refreshed["refresh_token"],
        "token_type_hint" => "refresh_token"
      })

    assert response(revoke_conn, 200) == ""
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp path_with_query(location) do
    uri = URI.parse(location)
    query = if uri.query, do: "?#{uri.query}", else: ""
    "#{uri.path}#{query}"
  end

  defp form_inputs(html, selector) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#{selector} input")
    |> Enum.reduce(%{}, fn input, params ->
      name = input |> Floki.attribute("name") |> List.first()
      value = input |> Floki.attribute("value") |> List.first()

      if name do
        Map.put(params, name, value || "")
      else
        params
      end
    end)
  end

  defp put_basic_auth(conn, client_id, secret) do
    credentials = Base.encode64("#{client_id}:#{secret}")
    put_req_header(conn, "authorization", "Basic #{credentials}")
  end

  defp fetch_string!(map, key) do
    value = Map.fetch!(map, key)
    assert is_binary(value)
    value
  end

  defp scope_includes?(scopes, scope) when is_binary(scopes) do
    scopes |> String.split() |> Enum.member?(scope)
  end

  defp scope_includes?(scopes, scope) when is_list(scopes), do: scope in scopes
  defp scope_includes?(_scopes, _scope), do: false

  defp verify_jwt_with_jwks!(jwt, %{"keys" => keys}) when is_list(keys) do
    Enum.find_value(keys, fn jwk ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(jwk), ["RS256"], jwt) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> claims
        _invalid -> nil
      end
    end) || flunk("JWT did not verify against JWKS")
  end
end
