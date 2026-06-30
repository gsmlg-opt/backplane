defmodule Backplane.Auth.TokensTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.SigningKey
  alias Backplane.Repo

  test "publishes an active signing key as JWKS" do
    assert {:ok, %SigningKey{} = key} = Auth.Tokens.ensure_active_signing_key()

    assert %{"keys" => [%{"kid" => kid, "use" => "sig", "alg" => "RS256"}]} =
             Auth.Tokens.jwks()

    assert kid == key.kid
  end

  test "stores private signing keys encrypted at rest" do
    assert {:ok, %SigningKey{} = key} = Auth.Tokens.ensure_active_signing_key()

    assert is_binary(key.encrypted_private_jwk)
    assert {:ok, raw_jwk} = Backplane.Settings.Encryption.decrypt(key.encrypted_private_jwk)
    assert %{"kid" => kid, "d" => private_exponent} = Jason.decode!(raw_jwk)
    assert kid == key.kid
    assert is_binary(private_exponent)
  end

  test "issues and verifies access and ID token claims" do
    user = auth_user_fixture!(email: "alice@example.com", name: "Alice")
    client = confidential_client!(scopes: ["openid", "profile", "email", "gsmlg:read"])

    assert {:ok, tokens} =
             Auth.Tokens.issue_access_token(
               user,
               client,
               ["openid", "profile", "email", "gsmlg:read"],
               nonce: "nonce-1"
             )

    assert is_binary(tokens.access_token)
    assert is_binary(tokens.refresh_token)
    assert is_binary(tokens.id_token)
    assert tokens.token_type == "Bearer"
    assert tokens.expires_in > 0

    assert {:ok, access_claims} = Auth.Tokens.verify_access_token(tokens.access_token)
    assert access_claims["iss"] == Backplane.WebOrigins.api_base_url()
    assert access_claims["sub"] == user.id
    assert access_claims["aud"] == client.id
    assert access_claims["client_id"] == client.id
    assert "gsmlg:read" in String.split(access_claims["scope"])

    jwks = Auth.Tokens.jwks()
    assert id_claims = verify_with_jwks!(tokens.id_token, jwks)
    assert id_claims["sub"] == user.id
    assert id_claims["aud"] == client.id
    assert id_claims["nonce"] == "nonce-1"
    assert id_claims["email"] == "alice@example.com"
  end

  test "introspects and revokes access tokens" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid", "gsmlg:read"])
    assert {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid", "gsmlg:read"])

    assert {:ok, active} = Auth.Tokens.introspect(tokens.access_token, client)
    assert active.active
    assert active.sub == user.id
    assert active.client_id == client.id
    assert "gsmlg:read" in String.split(active.scope)

    assert :ok = Auth.Tokens.revoke(tokens.access_token, client)
    assert {:ok, inactive} = Auth.Tokens.introspect(tokens.access_token, client)
    refute inactive.active
  end

  test "lists token metadata and revokes a token by id" do
    user = auth_user_fixture!(email: "listed@example.com")
    client = confidential_client!(scopes: ["openid"])
    assert {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid"])

    assert [%Boruta.Ecto.Token{id: token_id, client: listed_client}] = Auth.Tokens.list_tokens()
    assert token_id == tokens.token.id
    assert listed_client.id == client.id

    assert {:ok, revoked} = Auth.Tokens.revoke_token_by_id(token_id)
    assert revoked.revoked_at
    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(tokens.access_token)
  end

  test "rotates refresh tokens and invalidates the previous refresh token" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    assert {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid"])

    assert {:ok, rotated} = Auth.Tokens.rotate_refresh_token(tokens.refresh_token, client)
    assert rotated.refresh_token != tokens.refresh_token
    assert rotated.access_token != tokens.access_token

    assert {:error, :reuse_detected} =
             Auth.Tokens.rotate_refresh_token(tokens.refresh_token, client)

    assert [event] = Auth.Audit.list_events(event_type: "token.refresh_reuse_detected")
    assert event.severity == "error"
    assert event.target_type == "oauth_token"
    assert event.target_id == tokens.token.id
  end

  test "rejects authorization codes when the user lacks requested RBAC scopes" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid", "profile", "app:read"])

    assert {:error, :invalid_scope} =
             Auth.Tokens.issue_authorization_code(
               user,
               client,
               authorization_code_params(scope: "openid profile app:read")
             )

    grant_user_scopes!(user, ["openid", "profile", "app:read"])

    assert {:ok, %{code: code}} =
             Auth.Tokens.issue_authorization_code(
               user,
               client,
               authorization_code_params(scope: "openid profile app:read")
             )

    assert is_binary(code)
  end

  test "rejects access tokens after disabling the resource owner" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    assert {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid"])

    assert {:ok, _claims} = Auth.Tokens.verify_access_token(tokens.access_token)

    assert {:ok, _disabled} = Auth.Accounts.disable_user(user)

    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(tokens.access_token)

    assert {:error, :resource_owner_inactive} =
             Auth.Tokens.rotate_refresh_token(tokens.refresh_token, client)
  end

  test "rejects access and refresh tokens after disabling the OAuth client" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    assert {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid"])

    assert {:ok, disabled_client} = Auth.OAuth.disable_client(client)

    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(tokens.access_token)

    assert {:error, :invalid_client} =
             Auth.Tokens.rotate_refresh_token(tokens.refresh_token, disabled_client)
  end

  test "enforces refresh token TTL during rotation" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"], refresh_token_ttl: 1)
    assert {:ok, tokens} = Auth.Tokens.issue_access_token(user, client, ["openid"])

    expired_at = DateTime.add(DateTime.utc_now(), -5, :second)

    tokens.token
    |> Ecto.Changeset.change(inserted_at: expired_at, updated_at: expired_at)
    |> Repo.update!()

    assert {:error, :expired_refresh_token} =
             Auth.Tokens.rotate_refresh_token(tokens.refresh_token, client)
  end

  defp confidential_client!(attrs) do
    Enum.each(Keyword.fetch!(attrs, :scopes), &scope!/1)

    assert {:ok, %{client: client}} =
             Auth.OAuth.create_client(%{
               name: "Token Test Client",
               redirect_uris: ["https://app.example.test/auth/callback"],
               scopes: Keyword.fetch!(attrs, :scopes),
               confidential: true,
               pkce: true,
               refresh_token_ttl: Keyword.get(attrs, :refresh_token_ttl, 2_592_000)
             })

    client
  end

  defp authorization_code_params(overrides) do
    Map.merge(
      %{
        "redirect_uri" => "https://app.example.test/auth/callback",
        "scope" => "openid",
        "code_challenge" => pkce_challenge("authorization-code-verifier"),
        "code_challenge_method" => "S256"
      },
      stringify_keys(overrides)
    )
  end

  defp stringify_keys(values) do
    Map.new(values, fn {key, value} -> {to_string(key), value} end)
  end

  defp grant_user_scopes!(user, scopes) do
    Enum.each(scopes, &scope!/1)

    role_name = "role-#{System.unique_integer([:positive])}"
    assert {:ok, role} = Auth.RBAC.create_role(%{name: role_name, label: role_name})

    Enum.each(scopes, fn scope ->
      assert {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, scope)
    end)

    assert {:ok, _user_role} = Auth.RBAC.assign_user_role(user, role)
    role
  end

  defp scope!(name) do
    Auth.OAuth.get_scope(name) ||
      create_scope!(name)
  end

  defp create_scope!(name) do
    assert {:ok, scope} = Auth.OAuth.create_scope(%{name: name, label: name, public: true})
    scope
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp verify_with_jwks!(jwt, %{"keys" => keys}) do
    Enum.find_value(keys, fn jwk ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(jwk), ["RS256"], jwt) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> claims
        _invalid -> nil
      end
    end) || flunk("JWT did not verify against JWKS")
  end
end
