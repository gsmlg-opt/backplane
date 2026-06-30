defmodule Backplane.Auth.Tokens do
  @moduledoc "JWT signing, refresh-token rotation, introspection, and revocation."

  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.Auth.Accounts
  alias Backplane.Auth.Schemas.{SigningKey, User}
  alias Backplane.Repo
  alias Backplane.WebOrigins
  alias Boruta.Ecto.{Client, Token}

  @alg "RS256"
  @access_token_ttl 3_600

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

  def issue_access_token(%User{} = user, %Client{} = client, scopes, opts \\ [])
      when is_list(scopes) do
    with {:ok, key} <- ensure_active_signing_key() do
      now = System.system_time(:second)
      expires_in = Keyword.get(opts, :expires_in, client.access_token_ttl || @access_token_ttl)
      expires_at = now + expires_in
      scope = scope_string(scopes)
      token_id = Ecto.UUID.generate()

      access_claims = %{
        "iss" => WebOrigins.api_base_url(),
        "sub" => user.id,
        "aud" => client.id,
        "client_id" => client.id,
        "scope" => scope,
        "iat" => now,
        "exp" => expires_at,
        "jti" => token_id
      }

      access_token = sign_jwt!(key, access_claims)
      refresh_token = random_token()

      id_token =
        if "openid" in scopes do
          issue_id_token!(key, user, client, now, expires_at, Keyword.get(opts, :nonce))
        end

      attrs = %{
        id: token_id,
        type: "access_token",
        value: access_token,
        refresh_token: refresh_token,
        client_id: client.id,
        sub: user.id,
        scope: scope,
        nonce: Keyword.get(opts, :nonce),
        redirect_uri: Keyword.get(opts, :redirect_uri),
        previous_token: Keyword.get(opts, :previous_token),
        expires_at: expires_at
      }

      with {:ok, token} <- insert_token(attrs) do
        {:ok,
         %{
           access_token: access_token,
           refresh_token: refresh_token,
           id_token: id_token,
           token_type: "Bearer",
           expires_in: expires_in,
           scope: scope,
           token: token
         }}
      end
    end
  end

  def issue_id_token(%User{} = user, %Client{} = client, opts \\ []) do
    with {:ok, key} <- ensure_active_signing_key() do
      now = System.system_time(:second)
      expires_at = now + Keyword.get(opts, :expires_in, client.id_token_ttl || @access_token_ttl)

      {:ok, issue_id_token!(key, user, client, now, expires_at, Keyword.get(opts, :nonce))}
    end
  end

  def issue_authorization_code(%User{} = user, %Client{} = client, params) when is_map(params) do
    method = Map.get(params, "code_challenge_method") || Map.get(params, :code_challenge_method)
    challenge = Map.get(params, "code_challenge") || Map.get(params, :code_challenge)

    cond do
      method != "S256" ->
        {:error, :unsupported_code_challenge_method}

      not is_binary(challenge) or challenge == "" ->
        {:error, :missing_code_challenge}

      true ->
        code = random_token()
        now = System.system_time(:second)

        attrs = %{
          type: "code",
          value: code,
          client_id: client.id,
          sub: user.id,
          redirect_uri: Map.get(params, "redirect_uri") || Map.get(params, :redirect_uri),
          state: Map.get(params, "state") || Map.get(params, :state),
          nonce: Map.get(params, "nonce") || Map.get(params, :nonce),
          scope: Map.get(params, "scope") || Map.get(params, :scope) || "",
          code_challenge_hash: challenge,
          code_challenge_method: "S256",
          expires_at: now + (client.authorization_code_ttl || 60)
        }

        with {:ok, token} <- insert_token(attrs) do
          {:ok, %{code: code, token: token}}
        end
    end
  end

  def exchange_authorization_code(code, %Client{} = client, attrs) when is_binary(code) do
    with %Token{} = code_token <- get_code_token(code, client),
         :ok <- validate_code_token(code_token, attrs),
         {:ok, _revoked_code} <- code_token |> change(revoked_at: now()) |> Repo.update(),
         %User{} = user <- Accounts.get_user(code_token.sub) do
      issue_access_token(user, client, String.split(code_token.scope, " ", trim: true),
        nonce: code_token.nonce,
        redirect_uri: code_token.redirect_uri
      )
    else
      nil -> {:error, :invalid_grant}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_access_token(token) when is_binary(token) do
    with {:ok, claims} <- verify_jwt(token),
         :ok <- validate_expiration(claims),
         {:ok, _token} <- active_access_token(token) do
      {:ok, claims}
    end
  end

  def introspect(token, %Client{} = client) when is_binary(token) do
    case get_client_token(token, client) do
      %Token{} = token ->
        {:ok,
         %{
           active: active_token?(token),
           sub: token.sub,
           client_id: token.client_id,
           scope: token.scope,
           exp: token.expires_at
         }}

      nil ->
        {:ok, %{active: false}}
    end
  end

  def revoke(token, %Client{} = client) when is_binary(token) do
    case get_client_token(token, client) || get_client_refresh_token(token, client) do
      %Token{} = token ->
        token |> revoke_token() |> ok_result()

      nil ->
        :ok
    end
  end

  def rotate_refresh_token(refresh_token, %Client{} = client) when is_binary(refresh_token) do
    case get_client_refresh_token(refresh_token, client) do
      %Token{refresh_token_revoked_at: %DateTime{}} = token ->
        revoke_family(token)
        {:error, :reuse_detected}

      %Token{} = token ->
        with {:ok, _revoked} <-
               token
               |> change(refresh_token_revoked_at: now())
               |> Repo.update(),
             %User{} = user <- Accounts.get_user(token.sub) do
          issue_access_token(user, client, String.split(token.scope, " ", trim: true),
            nonce: token.nonce,
            redirect_uri: token.redirect_uri,
            previous_token: token.value
          )
        else
          nil -> {:error, :resource_owner_not_found}
          {:error, changeset} -> {:error, changeset}
        end

      nil ->
        {:error, :invalid_refresh_token}
    end
  end

  def find_active_access_token(token) when is_binary(token), do: active_access_token(token)

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
      private_jwk: private_jwk,
      public_jwk: public_jwk,
      active: true
    })
    |> Repo.insert()
  end

  defp issue_id_token!(key, user, client, now, expires_at, nonce) do
    claims =
      %{
        "iss" => WebOrigins.api_base_url(),
        "sub" => user.id,
        "aud" => client.id,
        "iat" => now,
        "exp" => expires_at,
        "email" => user.email,
        "email_verified" => true,
        "name" => user.name
      }
      |> maybe_put("nonce", nonce)

    sign_jwt!(key, claims)
  end

  defp sign_jwt!(%SigningKey{} = key, claims) do
    signer = JOSE.JWS.from_map(%{"alg" => @alg, "kid" => key.kid})

    key.private_jwk
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

  defp insert_token(attrs) do
    %Token{}
    |> change(attrs)
    |> foreign_key_constraint(:client_id)
    |> Repo.insert()
  end

  defp active_access_token(token) do
    case get_token_by_value(token) do
      %Token{} = token ->
        if active_token?(token), do: {:ok, token}, else: {:error, :invalid_token}

      nil ->
        {:error, :invalid_token}
    end
  end

  defp get_code_token(code, %Client{id: client_id}) do
    Token
    |> where([token], token.client_id == ^client_id)
    |> where([token], token.value == ^code)
    |> where([token], token.type == "code")
    |> Repo.one()
  end

  defp validate_code_token(%Token{} = token, attrs) do
    verifier = Map.get(attrs, "code_verifier") || Map.get(attrs, :code_verifier)
    redirect_uri = Map.get(attrs, "redirect_uri") || Map.get(attrs, :redirect_uri)

    cond do
      not active_token?(token) ->
        {:error, :invalid_grant}

      redirect_uri != token.redirect_uri ->
        {:error, :invalid_grant}

      not is_binary(verifier) ->
        {:error, :invalid_grant}

      pkce_challenge(verifier) != token.code_challenge_hash ->
        {:error, :invalid_grant}

      true ->
        :ok
    end
  end

  defp get_client_token(token, %Client{id: client_id}) do
    Token
    |> where([token], token.client_id == ^client_id)
    |> where([token], token.value == ^token)
    |> Repo.one()
  end

  defp get_client_refresh_token(refresh_token, %Client{id: client_id}) do
    Token
    |> where([token], token.client_id == ^client_id)
    |> where([token], token.refresh_token == ^refresh_token)
    |> Repo.one()
  end

  defp get_token_by_value(value) do
    Repo.get_by(Token, value: value)
  end

  defp active_token?(%Token{} = token) do
    token.expires_at > System.system_time(:second) and is_nil(token.revoked_at)
  end

  defp revoke_family(%Token{} = token) do
    Token
    |> where([candidate], candidate.client_id == ^token.client_id)
    |> where([candidate], candidate.sub == ^token.sub)
    |> Repo.update_all(set: [revoked_at: now(), refresh_token_revoked_at: now()])
  end

  defp revoke_token(%Token{} = token) do
    token
    |> change(revoked_at: now(), refresh_token_revoked_at: now())
    |> Repo.update()
  end

  defp ok_result({:ok, _token}), do: :ok
  defp ok_result({:error, changeset}), do: {:error, changeset}

  defp scope_string(scopes) do
    scopes
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp pkce_challenge(verifier) do
    :sha256
    |> :crypto.hash(verifier)
    |> Base.url_encode64(padding: false)
  end

  defp now, do: DateTime.utc_now()
end
