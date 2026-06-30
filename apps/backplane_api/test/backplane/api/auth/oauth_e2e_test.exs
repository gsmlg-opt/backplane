defmodule Backplane.Api.Auth.OAuthE2ETest do
  use Backplane.Api.ConnCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth

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

    grant_scopes!(user, ["openid", "profile", "email", "gsmlg:read"])

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
    assert get_resp_header(token_conn, "cache-control") == ["no-store"]
    assert get_resp_header(token_conn, "pragma") == ["no-cache"]
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

  test "public first-party app completes authorization code PKCE flow without a client secret",
       %{conn: conn} do
    user =
      auth_user_fixture!(email: "public@example.com", name: "Public User", password: @password)

    client =
      oauth_client_fixture!(
        name: "GSMLG Umbrella",
        redirect_uris: ["http://localhost:4555/auth/callback"],
        scopes: ["openid", "profile", "email", "app:read"],
        confidential: false,
        pkce: true
      )

    {verifier, challenge} = pkce_pair()

    token_response =
      complete_authorization_code_flow(conn, user, client, verifier, challenge,
        redirect_uri: "http://localhost:4555/auth/callback",
        scope: "openid profile email app:read"
      )

    assert token_response["token_type"] == "Bearer"
    assert fetch_string!(token_response, "access_token")
    assert fetch_string!(token_response, "refresh_token")
    assert fetch_string!(token_response, "id_token")
    assert scope_includes?(token_response["scope"], "app:read")
  end

  test "confidential client introspection rejects a bad client secret", %{conn: conn} do
    user = auth_user_fixture!(email: "introspect@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid", "profile", "email", "app:read"])
    {verifier, challenge} = pkce_pair()

    token_response =
      complete_authorization_code_flow(conn, user, client, verifier, challenge,
        redirect_uri: hd(client.redirect_uris),
        scope: "openid profile email app:read"
      )

    active_body =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/introspect", %{"token" => token_response["access_token"]})
      |> json_response(200)

    assert active_body["active"] == true
    assert active_body["sub"] == user.id
    assert active_body["client_id"] == client.id

    bad_secret_body =
      conn
      |> recycle()
      |> put_basic_auth(client.id, "wrong-secret")
      |> post("/oauth/introspect", %{"token" => token_response["access_token"]})
      |> json_response(401)

    assert bad_secret_body["error"] == "invalid_client"
  end

  test "reused authorization code is rejected", %{conn: conn} do
    user = auth_user_fixture!(email: "reuse-code@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid", "profile", "email"])
    verifier = "reused-code-verifier-that-is-long-enough"

    code =
      authorize_code!(
        conn,
        user,
        client,
        verifier,
        hd(client.redirect_uris),
        "openid profile email"
      )

    first =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => verifier
      })

    assert json_response(first, 200)["access_token"]

    second =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => hd(client.redirect_uris),
        "code_verifier" => verifier
      })
      |> json_response(400)

    assert second["error"] == "invalid_grant"
  end

  test "authorization rejects scopes not granted to the user through RBAC", %{conn: conn} do
    user = auth_user_fixture!(email: "missing-rbac@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid", "profile", "email", "app:read"])

    {verifier, challenge} = pkce_pair()

    authorize_conn =
      conn
      |> recycle()
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => hd(client.redirect_uris),
        "response_type" => "code",
        "scope" => "openid profile email app:read",
        "state" => "state-missing-rbac",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    login_location = redirected_to(authorize_conn, 302)

    login_conn =
      authorize_conn
      |> recycle()
      |> get(path_with_query(login_location))

    login_params =
      login_conn
      |> html_response(200)
      |> form_inputs("#oauth-login-form")
      |> Map.merge(%{"email" => user.email, "password" => @password})

    body =
      login_conn
      |> recycle()
      |> post("/oauth/login", login_params)
      |> response(400)

    assert body == "invalid_scope"
    assert is_binary(verifier)
  end

  test "disabled clients cannot authorize or use the token endpoint", %{conn: conn} do
    client = oauth_client_fixture!(scopes: ["openid"], redirect_uris: [@redirect_uri])
    assert {:ok, _disabled} = client.id |> Auth.OAuth.get_client() |> Auth.OAuth.disable_client()

    authorize_body =
      conn
      |> recycle()
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "scope" => "openid",
        "state" => "state-disabled-client",
        "code_challenge" => pkce_challenge("disabled-client-verifier"),
        "code_challenge_method" => "S256"
      })
      |> response(400)

    assert authorize_body == "invalid_client"

    token_body =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => "missing-refresh"
      })
      |> json_response(401)

    assert token_body["error"] == "invalid_client"
  end

  test "userinfo only exposes claims allowed by OIDC scopes", %{conn: conn} do
    user = auth_user_fixture!(email: "userinfo-scopes@example.com", name: "Scoped User")
    client = oauth_client_fixture!(scopes: ["openid", "profile", "email", "app:read"])

    assert {:ok, openid_tokens} =
             Auth.Tokens.issue_access_token(
               Auth.Accounts.get_user(user.id),
               Auth.OAuth.get_client(client.id),
               [
                 "openid"
               ]
             )

    openid_body =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{openid_tokens.access_token}")
      |> get("/oauth/userinfo")
      |> json_response(200)

    assert openid_body["sub"] == user.id
    refute Map.has_key?(openid_body, "email")
    refute Map.has_key?(openid_body, "name")

    assert {:ok, app_tokens} =
             Auth.Tokens.issue_access_token(
               Auth.Accounts.get_user(user.id),
               Auth.OAuth.get_client(client.id),
               [
                 "app:read"
               ]
             )

    app_body =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{app_tokens.access_token}")
      |> get("/oauth/userinfo")
      |> json_response(401)

    assert app_body["error"] == "invalid_token"
  end

  test "revoking the persisted browser session forces OAuth login again", %{conn: conn} do
    user = auth_user_fixture!(email: "browser-session@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid"], redirect_uris: [@redirect_uri])
    grant_scopes!(user, ["openid"])
    {verifier, challenge} = pkce_pair()

    authorize_conn =
      conn
      |> recycle()
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "scope" => "openid",
        "state" => "state-session-revoke",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    login_location = redirected_to(authorize_conn, 302)

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

    assert redirected_to(callback_conn, 302) =~ @redirect_uri

    [session] = Auth.Accounts.list_sessions()
    assert session.user_id == user.id
    assert {:ok, _revoked} = Auth.Accounts.revoke_session(session)

    next_authorize_conn =
      callback_conn
      |> recycle()
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "scope" => "openid",
        "state" => "state-session-revoked-next",
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256"
      })

    assert redirected_to(next_authorize_conn, 302) == "/oauth/login"
  end

  test "mismatched redirect URI is rejected before login", %{conn: conn} do
    client = oauth_client_fixture!(redirect_uris: [@redirect_uri])

    body =
      conn
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => "https://evil.example.test/auth/callback",
        "response_type" => "code",
        "scope" => "openid profile email",
        "state" => "state-redirect-mismatch",
        "code_challenge" => pkce_challenge("redirect-mismatch-verifier"),
        "code_challenge_method" => "S256"
      })
      |> response(400)

    assert body == "invalid_request"
  end

  test "missing PKCE verifier is rejected during token exchange", %{conn: conn} do
    user = auth_user_fixture!(email: "missing-verifier@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid"])
    verifier = "missing-verifier-valid-original"
    code = authorize_code!(conn, user, client, verifier, hd(client.redirect_uris), "openid")

    body =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => hd(client.redirect_uris)
      })
      |> json_response(400)

    assert body["error"] == "invalid_grant"
  end

  test "refresh token reuse revokes the latest token family", %{conn: conn} do
    user = auth_user_fixture!(email: "reuse-refresh@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid", "profile", "email"])
    {verifier, challenge} = pkce_pair()

    token_response =
      complete_authorization_code_flow(conn, user, client, verifier, challenge,
        redirect_uri: hd(client.redirect_uris),
        scope: "openid profile email"
      )

    refreshed =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => token_response["refresh_token"]
      })
      |> json_response(200)

    reused =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => token_response["refresh_token"]
      })
      |> json_response(400)

    assert reused["error"] == "invalid_grant"

    revoked_userinfo =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{refreshed["access_token"]}")
      |> get("/oauth/userinfo")
      |> json_response(401)

    assert revoked_userinfo["error"] == "invalid_token"
  end

  test "revoked access token fails userinfo", %{conn: conn} do
    user = auth_user_fixture!(email: "revoked-access@example.com", password: @password)
    client = oauth_client_fixture!(scopes: ["openid", "profile", "email"])
    {verifier, challenge} = pkce_pair()

    token_response =
      complete_authorization_code_flow(conn, user, client, verifier, challenge,
        redirect_uri: hd(client.redirect_uris),
        scope: "openid profile email"
      )

    revoke_conn =
      conn
      |> recycle()
      |> put_basic_auth(client.id, client.plaintext_secret)
      |> post("/oauth/revoke", %{"token" => token_response["access_token"]})

    assert response(revoke_conn, 200) == ""

    body =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{token_response["access_token"]}")
      |> get("/oauth/userinfo")
      |> json_response(401)

    assert body["error"] == "invalid_token"
  end

  test "unsupported implicit response type is rejected", %{conn: conn} do
    client = oauth_client_fixture!(redirect_uris: [@redirect_uri])

    body =
      conn
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "response_type" => "token",
        "scope" => "openid profile email",
        "state" => "state-implicit",
        "code_challenge" => pkce_challenge("implicit-verifier"),
        "code_challenge_method" => "S256"
      })
      |> response(400)

    assert body == "unsupported_response_type"
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp pkce_pair do
    verifier =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    {verifier, pkce_challenge(verifier)}
  end

  defp complete_authorization_code_flow(conn, user, client, verifier, challenge, opts) do
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    scope = Keyword.fetch!(opts, :scope)
    code = authorize_code!(conn, user, client, verifier, redirect_uri, scope, challenge)

    token_params = %{
      "grant_type" => "authorization_code",
      "client_id" => client.id,
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier
    }

    conn
    |> recycle()
    |> maybe_put_basic_auth(client)
    |> post("/oauth/token", token_params)
    |> json_response(200)
  end

  defp authorize_code!(conn, user, client, verifier, redirect_uri, scope) do
    authorize_code!(conn, user, client, verifier, redirect_uri, scope, pkce_challenge(verifier))
  end

  defp authorize_code!(conn, user, client, _verifier, redirect_uri, scope, challenge) do
    grant_scopes!(user, String.split(scope, " ", trim: true))

    authorize_conn =
      conn
      |> recycle()
      |> get("/oauth/authorize", %{
        "client_id" => client.id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => scope,
        "state" => "state-#{System.unique_integer([:positive])}",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    login_location = redirected_to(authorize_conn, 302)

    login_conn =
      authorize_conn
      |> recycle()
      |> get(path_with_query(login_location))

    login_params =
      login_conn
      |> html_response(200)
      |> form_inputs("#oauth-login-form")
      |> Map.merge(%{"email" => user.email, "password" => @password})

    callback_uri =
      login_conn
      |> recycle()
      |> post("/oauth/login", login_params)
      |> redirected_to(302)
      |> URI.parse()

    callback_uri.query
    |> URI.decode_query()
    |> Map.fetch!("code")
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

  defp maybe_put_basic_auth(conn, %{plaintext_secret: secret, id: client_id}) do
    put_basic_auth(conn, client_id, secret)
  end

  defp maybe_put_basic_auth(conn, _client), do: conn

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

  defp grant_scopes!(user, scopes) do
    Enum.each(scopes, fn scope ->
      Auth.OAuth.get_scope(scope) ||
        Auth.OAuth.create_scope(%{name: scope, label: scope, public: true})
    end)

    role_name = "oauth-e2e-#{System.unique_integer([:positive])}"
    assert {:ok, role} = Auth.RBAC.create_role(%{name: role_name, label: role_name})

    Enum.each(scopes, fn scope ->
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, scope)
    end)

    assert {:ok, _user_role} = Auth.RBAC.assign_user_role(user, role)
    role
  end

  defp verify_jwt_with_jwks!(jwt, %{"keys" => keys}) when is_list(keys) do
    Enum.find_value(keys, fn jwk ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(jwk), ["RS256"], jwt) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> claims
        _invalid -> nil
      end
    end) || flunk("JWT did not verify against JWKS")
  end
end
