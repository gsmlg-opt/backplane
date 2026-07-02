defmodule Backplane.Auth.Tokens do
  @moduledoc """
  JWT signing keys, access-token verification, and token administration for
  Backplane Auth.

  OAuth grant flows (authorize, token, introspect, revoke) are delegated to
  Boruta; this module owns what Boruta does not: the server-wide RS256 signing
  key used for JWT access tokens, local verification of those JWTs, refresh
  token reuse detection with family revocation, and admin-facing token
  management.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Auth.{Accounts, Audit, OAuth}
  alias Backplane.Auth.Schemas.{SigningKey, User}
  alias Backplane.Repo
  alias Backplane.Settings.Encryption
  alias Boruta.Ecto.{Client, Token}

  @alg "RS256"
  @access_token_ttl 3_600

  ## Signing keys / JWKS

  def ensure_active_signing_key do
    SigningKey
    |> where(active: true)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      %SigningKey{} = key -> {:ok, key}
      nil -> create_signing_key()
    end
  end

  def jwks do
    keys =
      SigningKey
      |> where([key], key.active == true or not is_nil(key.retired_at))
      |> order_by(desc: :active, desc: :inserted_at)
      |> Repo.all()
      |> Enum.map(& &1.public_jwk)

    %{"keys" => keys}
  end

  @doc """
  Signs the RS256 JWT value for a Boruta access token.

  Invoked from `Backplane.Auth.AccessTokenGenerator` while Boruta builds the
  token row. `expires_at` is not set on the struct at that point, so `exp` is
  derived from the client's `access_token_ttl`.
  """
  def sign_access_token!(%Token{client_id: client_id, sub: sub, scope: scope} = token) do
    {:ok, key} = ensure_active_signing_key()
    now = System.system_time(:second)
    ttl = token.access_token_ttl || @access_token_ttl

    sign_jwt!(key, %{
      "iss" => Boruta.Config.issuer(),
      "sub" => sub,
      "aud" => client_id,
      "client_id" => client_id,
      "scope" => scope || "",
      "iat" => now,
      "exp" => now + ttl,
      "jti" => Ecto.UUID.generate()
    })
  end

  ## Access token verification (resource-server side)

  def verify_access_token(token) when is_binary(token) do
    with {:ok, claims} <- verify_jwt(token),
         :ok <- validate_expiration(claims),
         {:ok, token_record} <- active_access_token(token),
         :ok <- validate_token_principals(token_record) do
      {:ok, claims}
    end
  end

  def find_active_access_token(token) when is_binary(token), do: active_access_token(token)

  ## Refresh token reuse detection

  @doc """
  Checks whether a failed refresh grant presented an already-rotated refresh
  token. On reuse, audits the event and revokes every token the client holds
  for that subject. Called from the token endpoint error path.
  """
  def detect_refresh_token_reuse(refresh_token, client_id)
      when is_binary(refresh_token) and is_binary(client_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(client_id),
         %Token{} = token <- get_reused_refresh_token(refresh_token, client_id) do
      audit_refresh_reuse(token)
      revoke_family(token)
      :reuse_detected
    else
      _no_reuse -> :ok
    end
  end

  def detect_refresh_token_reuse(_refresh_token, _client_id), do: :ok

  ## Admin token management

  def list_tokens(limit \\ 100) when is_integer(limit) and limit > 0 do
    Token
    |> preload(:client)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def revoke_token_by_id(id) when is_binary(id) do
    case Repo.get(Token, id) do
      %Token{} = token -> revoke_token(token)
      nil -> {:error, :not_found}
    end
  end

  ## Internals

  defp create_signing_key do
    kid = "auth-#{Ecto.UUID.generate()}"
    private_key = JOSE.JWK.generate_key({:rsa, 2048, 65_537})
    public_key = JOSE.JWK.to_public(private_key)
    {_type, private_jwk} = JOSE.JWK.to_map(private_key)
    {_type, public_jwk} = JOSE.JWK.to_map(public_key)

    private_jwk = Map.merge(private_jwk, %{"alg" => @alg, "kid" => kid, "use" => "sig"})
    public_jwk = Map.merge(public_jwk, %{"alg" => @alg, "kid" => kid, "use" => "sig"})

    %SigningKey{}
    |> SigningKey.changeset(%{
      kid: kid,
      encrypted_private_jwk: Encryption.encrypt(Jason.encode!(private_jwk)),
      public_jwk: public_jwk,
      active: true
    })
    |> Repo.insert()
  end

  defp sign_jwt!(%SigningKey{} = key, claims) do
    signer = JOSE.JWS.from_map(%{"alg" => @alg, "kid" => key.kid})

    private_jwk!(key)
    |> JOSE.JWK.from_map()
    |> JOSE.JWT.sign(signer, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp verify_jwt(token) do
    jwks()
    |> Map.fetch!("keys")
    |> Enum.find_value(fn jwk ->
      case JOSE.JWT.verify_strict(JOSE.JWK.from_map(jwk), [@alg], token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _invalid -> nil
      end
    end)
    |> case do
      {:ok, claims} -> {:ok, claims}
      nil -> {:error, :invalid_token}
    end
  rescue
    _error -> {:error, :invalid_token}
  end

  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end

  defp validate_expiration(_claims), do: {:error, :invalid_token}

  defp active_access_token(token) do
    case Repo.get_by(Token, value: token) do
      %Token{} = token ->
        if active_token?(token), do: {:ok, token}, else: {:error, :invalid_token}

      nil ->
        {:error, :invalid_token}
    end
  end

  defp validate_token_principals(%Token{} = token) do
    with %User{} = user <- Accounts.get_user(token.sub),
         :ok <- validate_active_user(user),
         %Client{} = client <- OAuth.get_client(token.client_id),
         :ok <- validate_active_client(client) do
      :ok
    else
      _invalid -> {:error, :invalid_token}
    end
  end

  defp validate_active_user(%User{active: true}), do: :ok
  defp validate_active_user(%User{active: false}), do: {:error, :resource_owner_inactive}
  defp validate_active_user(_user), do: {:error, :resource_owner_not_found}

  defp validate_active_client(%Client{} = client) do
    if OAuth.client_enabled?(client), do: :ok, else: {:error, :invalid_client}
  end

  defp validate_active_client(_client), do: {:error, :invalid_client}

  defp active_token?(%Token{} = token) do
    token.expires_at > System.system_time(:second) and is_nil(token.revoked_at)
  end

  defp get_reused_refresh_token(refresh_token, client_id) do
    Token
    |> where([token], token.client_id == ^client_id)
    |> where([token], token.refresh_token == ^refresh_token)
    |> where([token], not is_nil(token.refresh_token_revoked_at))
    |> Repo.one()
  end

  defp audit_refresh_reuse(%Token{} = token) do
    Audit.record(
      "token.refresh_reuse_detected",
      %{actor_type: "oauth_client", actor_id: token.client_id},
      %{
        target_type: "oauth_token",
        target_id: token.id,
        severity: "error",
        metadata: %{"sub" => token.sub}
      }
    )
  end

  defp revoke_family(%Token{client_id: client_id, sub: sub}) do
    now = now()

    tokens =
      Token
      |> where([candidate], candidate.client_id == ^client_id)
      |> where([candidate], candidate.sub == ^sub)
      |> Repo.all()

    Token
    |> where([candidate], candidate.client_id == ^client_id)
    |> where([candidate], candidate.sub == ^sub)
    |> Repo.update_all(set: [revoked_at: now, refresh_token_revoked_at: now, updated_at: now])

    Enum.each(tokens, &invalidate_boruta_cache/1)
  end

  defp revoke_token(%Token{} = token) do
    result =
      token
      |> change(revoked_at: now(), refresh_token_revoked_at: now())
      |> Repo.update()

    with {:ok, revoked} <- result do
      invalidate_boruta_cache(revoked)
      {:ok, revoked}
    end
  end

  # Boruta serves token lookups from its Nebulex cache; direct Repo writes
  # must invalidate the corresponding entries or revocation is delayed until
  # the cache entry expires.
  defp invalidate_boruta_cache(%Token{type: type, value: value, refresh_token: refresh_token}) do
    Boruta.Ecto.TokenStore.invalidate(%Boruta.Oauth.Token{
      type: type,
      value: value,
      refresh_token: refresh_token
    })
  end

  defp now, do: DateTime.utc_now()

  defp private_jwk!(%SigningKey{encrypted_private_jwk: encrypted}) do
    with {:ok, raw_jwk} <- Encryption.decrypt(encrypted),
         {:ok, private_jwk} <- Jason.decode(raw_jwk) do
      private_jwk
    else
      _error -> raise "could not decrypt auth signing key #{inspect(encrypted)}"
    end
  end
end
