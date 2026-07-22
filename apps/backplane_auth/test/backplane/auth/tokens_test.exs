defmodule Backplane.Auth.TokensTest do
  use Backplane.Auth.DataCase, async: false

  import Backplane.Auth.Fixtures

  alias Backplane.Auth
  alias Backplane.Auth.Resources
  alias Backplane.Auth.Schemas.{OAuthTokenResource, SigningKey}
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
    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "resource fixtures sign canonical audiences through code lineage" do
    for {resource, scope} <- [mcp: "github::*", v1: "llm::invoke"] do
      {_user, client, token} = resource_token_fixture!(resource, scope)

      assert {:ok, auth} = Auth.Tokens.verify_resource_access_token(token.value, resource)
      assert auth.claims["iss"] == Boruta.Config.issuer()
      assert auth.claims["aud"] == Resources.uri(resource)
      assert auth.claims["client_id"] == client.id
      assert auth.claims["sub"] == token.sub
      assert auth.claims["exp"] > System.system_time(:second)
      assert auth.scopes == [scope]
    end
  end

  test "signs the canonical audience through access-token lineage" do
    {user, client, previous_token} = resource_token_fixture!(:mcp, "github::*")

    oauth_client =
      client
      |> Boruta.Ecto.OauthMapper.to_oauth_schema()

    assert {:ok, oauth_token} =
             Boruta.Ecto.AccessTokens.create(
               %{
                 client: oauth_client,
                 sub: user.id,
                 scope: "github::*",
                 previous_token: previous_token.value
               },
               refresh_token: true
             )

    token = Repo.get_by!(Token, type: "access_token", value: oauth_token.value)

    assert {:ok, _binding} =
             Auth.TokenResources.bind_issued("access_token", client.id, token.value, :mcp)

    assert %{"aud" => audience, "client_id" => client_id} =
             verify_with_jwks!(token.value, Auth.Tokens.jwks())

    assert audience == Resources.uri(:mcp)
    assert client_id == client.id
    assert {:ok, _auth} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "fails closed when named code or access-token lineage is missing" do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [:mcp], scopes: ["github::*"])
    client = Auth.OAuth.get_client(client.id)
    oauth_client = Boruta.Ecto.OauthMapper.to_oauth_schema(client)
    missing_code = "missing-code-#{System.unique_integer([:positive])}"
    missing_token = "missing-token-#{System.unique_integer([:positive])}"
    message = "OAuth token resource lineage could not be resolved"

    assert_raise Auth.TokenResources.LineageError, message, fn ->
      Boruta.Ecto.AccessTokens.create(
        %{
          client: oauth_client,
          sub: user.id,
          scope: "github::*",
          previous_code: missing_code
        },
        refresh_token: true
      )
    end

    assert_raise Auth.TokenResources.LineageError, message, fn ->
      Boruta.Ecto.AccessTokens.create(
        %{
          client: oauth_client,
          sub: user.id,
          scope: "github::*",
          previous_token: missing_token
        },
        refresh_token: true
      )
    end

    refute Repo.get_by(Token,
             type: "access_token",
             client_id: client.id,
             previous_code: missing_code
           )

    refute Repo.get_by(Token,
             type: "access_token",
             client_id: client.id,
             previous_token: missing_token
           )
  end

  test "rejects a resource token requested for another resource" do
    {_user, _client, token} = resource_token_fixture!(:mcp, "github::*")

    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :v1)
  end

  test "rejects a resource token with an invalid issuer" do
    {_user, _client, token} = resource_token_fixture!(:mcp, "github::*")
    token = replace_claims!(token, &Map.put(&1, "iss", "https://other.example.test"))

    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "rejects expired and not-yet-valid resource-token claims" do
    {_user, _client, expired} = resource_token_fixture!(:mcp, "github::*")
    expired = replace_claims!(expired, &Map.put(&1, "exp", System.system_time(:second) - 1))

    {_user, _client, future} = resource_token_fixture!(:mcp, "github::*")
    future = replace_claims!(future, &Map.put(&1, "nbf", System.system_time(:second) + 60))

    {_user, _client, malformed} = resource_token_fixture!(:mcp, "github::*")
    malformed = replace_claims!(malformed, &Map.put(&1, "nbf", "tomorrow"))

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(expired.value, :mcp)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(future.value, :mcp)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(malformed.value, :mcp)
  end

  test "rejects revoked, missing, and non-access-token rows" do
    {_user, _client, revoked} = resource_token_fixture!(:mcp, "github::*")

    revoked =
      revoked
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
      |> Repo.update!()

    {_user, _client, missing} = resource_token_fixture!(:mcp, "github::*")
    missing_value = missing.value
    Repo.delete!(missing)

    {_user, _client, code} = resource_token_fixture!(:mcp, "github::*")
    code_value = code.value

    code
    |> Ecto.Changeset.change(type: "code")
    |> Repo.update!()

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(revoked.value, :mcp)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(missing_value, :mcp)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(code_value, :mcp)
  end

  test "rejects an access-token row without a persisted expiration" do
    {_user, _client, token} = resource_token_fixture!(:mcp, "github::*")

    token =
      token
      |> Ecto.Changeset.change(expires_at: nil)
      |> Repo.update!()

    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "rejects missing and wrong resource mappings" do
    {_user, _client, missing} = resource_token_fixture!(:mcp, "github::*")
    Repo.delete_all(OAuthTokenResource)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(missing.value, :mcp)

    {_user, _client, wrong} = resource_token_fixture!(:mcp, "github::*")
    binding = Repo.get_by!(OAuthTokenResource, oauth_token_id: wrong.id)

    binding
    |> Ecto.Changeset.change(resource: "v1")
    |> Repo.update!()

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(wrong.value, :mcp)
  end

  test "rejects signed audience, client, subject, and scope mismatches" do
    mismatches = [
      {"aud", Resources.uri(:v1)},
      {"client_id", Ecto.UUID.generate()},
      {"sub", Ecto.UUID.generate()},
      {"scope", "docs::read"}
    ]

    Enum.each(mismatches, fn {claim, value} ->
      {_user, _client, token} = resource_token_fixture!(:mcp, "github::*")
      token = replace_claims!(token, &Map.put(&1, claim, value))

      assert {:error, :invalid_token} =
               Auth.Tokens.verify_resource_access_token(token.value, :mcp)
    end)
  end

  test "rejects a matching malformed persisted and signed subject" do
    {_user, _client, token} = resource_token_fixture!(:mcp, "github::*")
    malformed_sub = "not-a-uuid"

    token =
      token
      |> Ecto.Changeset.change(sub: malformed_sub)
      |> Repo.update!()
      |> replace_claims!(&Map.put(&1, "sub", malformed_sub))

    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "rejects disabled and resource-unassigned clients" do
    {_user, disabled_client, disabled_token} =
      resource_token_fixture!(:mcp, "github::*")

    assert {:ok, _client} = Auth.OAuth.disable_client(disabled_client)

    {_user, unassigned_client, unassigned_token} =
      resource_token_fixture!(:mcp, "github::*")

    assert {:ok, _client} = Auth.OAuth.update_client_resources(unassigned_client, [:v1])

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(disabled_token.value, :mcp)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(unassigned_token.value, :mcp)
  end

  test "rejects a resource token after its OAuth client is deleted" do
    {_user, client, token} = resource_token_fixture!(:mcp, "github::*")

    Repo.delete!(client)

    assert Auth.OAuth.get_client(client.id) == nil
    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "rejects disabled and missing resource owners" do
    {disabled_user, _client, disabled_token} =
      resource_token_fixture!(:mcp, "github::*")

    assert {:ok, _user} = Auth.Accounts.disable_user(disabled_user)

    {missing_user, _client, missing_token} =
      resource_token_fixture!(:mcp, "github::*")

    Repo.delete!(missing_user)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(disabled_token.value, :mcp)

    assert {:error, :invalid_token} =
             Auth.Tokens.verify_resource_access_token(missing_token.value, :mcp)
  end

  test "a non-Backplane signature is the only not-oauth result" do
    assert :not_oauth = Auth.Tokens.verify_resource_access_token("opaque-pat", :mcp)

    {_user, _client, token} = resource_token_fixture!(:mcp, "github::*")
    Repo.delete_all(OAuthTokenResource)

    assert {:error, :invalid_token} = Auth.Tokens.verify_resource_access_token(token.value, :mcp)
  end

  test "an external RS256 signature is not OAuth" do
    external_key = JOSE.JWK.generate_key({:rsa, 2048, 65_537})
    signer = JOSE.JWS.from_map(%{"alg" => "RS256", "kid" => "external"})

    token =
      external_key
      |> JOSE.JWT.sign(signer, %{
        "iss" => Boruta.Config.issuer(),
        "sub" => Ecto.UUID.generate(),
        "aud" => Resources.uri(:mcp),
        "exp" => System.system_time(:second) + 60
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    assert :not_oauth = Auth.Tokens.verify_resource_access_token(token, :mcp)
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

  defp resource_token_fixture!(resource, scope) do
    user = auth_user_fixture!()
    client = oauth_client_fixture!(resources: [resource], scopes: [scope])
    client = Auth.OAuth.get_client(client.id)
    token = resource_access_token_fixture!(user, client, [scope], resource)

    {user, client, token}
  end

  defp replace_claims!(token, update) do
    claims = verify_with_jwks!(token.value, Auth.Tokens.jwks()) |> update.()
    {:ok, key} = Auth.Tokens.ensure_active_signing_key()
    {:ok, raw_jwk} = Backplane.Settings.Encryption.decrypt(key.encrypted_private_jwk)
    signer = JOSE.JWS.from_map(%{"alg" => "RS256", "kid" => key.kid})

    value =
      raw_jwk
      |> Jason.decode!()
      |> JOSE.JWK.from_map()
      |> JOSE.JWT.sign(signer, claims)
      |> JOSE.JWS.compact()
      |> elem(1)

    token
    |> Ecto.Changeset.change(value: value)
    |> Repo.update!()
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
