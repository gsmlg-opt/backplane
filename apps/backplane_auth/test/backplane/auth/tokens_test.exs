defmodule Backplane.Auth.TokensTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.SigningKey

  test "publishes an active signing key as JWKS" do
    assert {:ok, %SigningKey{} = key} = Auth.Tokens.ensure_active_signing_key()

    assert %{"keys" => [%{"kid" => kid, "use" => "sig", "alg" => "RS256"}]} =
             Auth.Tokens.jwks()

    assert kid == key.kid
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
  end

  defp confidential_client!(attrs) do
    Enum.each(Keyword.fetch!(attrs, :scopes), &scope!/1)

    assert {:ok, %{client: client}} =
             Auth.OAuth.create_client(%{
               name: "Token Test Client",
               redirect_uris: ["https://app.example.test/auth/callback"],
               scopes: Keyword.fetch!(attrs, :scopes),
               confidential: true,
               pkce: true
             })

    client
  end

  defp scope!(name) do
    assert {:ok, scope} = Auth.OAuth.create_scope(%{name: name, label: name, public: true})
    scope
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
