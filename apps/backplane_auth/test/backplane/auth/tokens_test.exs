defmodule Backplane.Auth.TokensTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Schemas.SigningKey
  alias Backplane.Repo
  alias Boruta.Ecto.Token

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

  test "signs Boruta access tokens as JWTs verifiable against JWKS" do
    user = auth_user_fixture!(email: "alice@example.com", name: "Alice")
    client = confidential_client!(scopes: ["openid", "gsmlg:read"])
    token = access_token_fixture!(user, client, ["openid", "gsmlg:read"])

    assert {:ok, claims} = Auth.Tokens.verify_access_token(token.value)
    assert claims["iss"] == Boruta.Config.issuer()
    assert claims["sub"] == user.id
    assert claims["aud"] == client.id
    assert claims["client_id"] == client.id
    assert "gsmlg:read" in String.split(claims["scope"])
    assert claims["exp"] > System.system_time(:second)

    assert verify_with_jwks!(token.value, Auth.Tokens.jwks())
  end

  test "lists token metadata and revokes a token by id" do
    user = auth_user_fixture!(email: "listed@example.com")
    client = confidential_client!(scopes: ["openid"])
    token = access_token_fixture!(user, client, ["openid"])

    assert [%Token{id: token_id, client: listed_client}] = Auth.Tokens.list_tokens()
    assert token_id == token.id
    assert listed_client.id == client.id

    assert {:ok, revoked} = Auth.Tokens.revoke_token_by_id(token_id)
    assert revoked.revoked_at
    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(token.value)
  end

  test "detects refresh token reuse and revokes the token family" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    rotated_token = access_token_fixture!(user, client, ["openid"])
    current_token = access_token_fixture!(user, client, ["openid"])

    rotated_token
    |> Ecto.Changeset.change(refresh_token_revoked_at: DateTime.utc_now())
    |> Repo.update!()

    assert :reuse_detected =
             Auth.Tokens.detect_refresh_token_reuse(rotated_token.refresh_token, client.id)

    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(current_token.value)

    assert [event] = Auth.Audit.list_events(event_type: "token.refresh_reuse_detected")
    assert event.severity == "error"
    assert event.target_type == "oauth_token"
    assert event.target_id == rotated_token.id
  end

  test "ignores refresh tokens that were never rotated" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    token = access_token_fixture!(user, client, ["openid"])

    assert :ok = Auth.Tokens.detect_refresh_token_reuse(token.refresh_token, client.id)
    assert :ok = Auth.Tokens.detect_refresh_token_reuse("unknown-token", client.id)
    assert :ok = Auth.Tokens.detect_refresh_token_reuse(token.refresh_token, "not-a-uuid")

    assert {:ok, _claims} = Auth.Tokens.verify_access_token(token.value)
  end

  test "rejects access tokens after disabling the resource owner" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    token = access_token_fixture!(user, client, ["openid"])

    assert {:ok, _claims} = Auth.Tokens.verify_access_token(token.value)

    assert {:ok, _disabled} = Auth.Accounts.disable_user(user)

    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(token.value)
  end

  test "rejects access tokens after disabling the OAuth client" do
    user = auth_user_fixture!()
    client = confidential_client!(scopes: ["openid"])
    token = access_token_fixture!(user, client, ["openid"])

    assert {:ok, _disabled} = Auth.OAuth.disable_client(client)

    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(token.value)
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

  defp scope!(name) do
    Auth.OAuth.get_scope(name) ||
      create_scope!(name)
  end

  defp create_scope!(name) do
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
