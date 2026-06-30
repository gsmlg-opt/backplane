defmodule Backplane.Accounts.FederatedLogin do
  @moduledoc """
  Domain engine for inbound upstream federated login.
  """

  alias Backplane.Accounts
  alias Backplane.Accounts.AuthProvider
  alias Backplane.Settings.OAuthStateStore
  alias Backplane.WebOrigins

  @state_purpose "accounts_federated_login"

  @type start_result ::
          {:ok, %{authorization_url: String.t(), state: String.t()}}
          | {:error,
             :provider_not_found
             | :provider_disabled
             | :missing_authorization_url
             | :invalid_return_to}

  @type complete_result ::
          {:ok, %{user: term(), identity: term(), resume_params: map()}}
          | {:error, term()}

  @spec start(String.t(), map(), keyword()) :: start_result()
  def start(provider_slug, resume_params \\ %{}, opts \\ [])

  def start(provider_slug, resume_params, opts)
      when is_binary(provider_slug) and is_map(resume_params) and is_list(opts) do
    with {:ok, resume_params} <- validate_resume_params(resume_params) do
      case Accounts.get_auth_provider_by_slug(provider_slug) do
        nil -> {:error, :provider_not_found}
        %AuthProvider{enabled: false} -> {:error, :provider_disabled}
        %AuthProvider{} = provider -> build_authorization(provider, resume_params, opts)
      end
    end
  end

  @spec complete(String.t(), map(), keyword()) :: complete_result()
  def complete(provider_slug, params, opts \\ [])

  def complete(provider_slug, %{"code" => code, "state" => state}, opts)
      when is_binary(provider_slug) and is_binary(code) and is_binary(state) and is_list(opts) do
    with %AuthProvider{} = provider <- Accounts.get_auth_provider_by_slug(provider_slug),
         :ok <- ensure_provider_enabled(provider),
         {:ok, state_attrs} <- pop_state(state),
         :ok <- validate_state(provider, state_attrs),
         {:ok, client_secret} <- Accounts.fetch_auth_provider_secret(provider),
         {:ok, token_response} <- exchange_code(provider, code, state_attrs, client_secret, opts),
         {:ok, claims} <- token_claims(provider, token_response, state_attrs, opts),
         :ok <- enforce_verified_email(claims),
         :ok <- enforce_email_domain(provider, claims),
         {:ok, provisioned} <- Accounts.provision_federated_user(provider, claims) do
      {:ok, Map.put(provisioned, :resume_params, Map.get(state_attrs, "resume_params", %{}))}
    else
      nil -> {:error, :provider_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete(_provider_slug, _params, _opts), do: {:error, :invalid_request}

  defp build_authorization(%AuthProvider{authorization_url: url}, _resume_params, _opts)
       when not is_binary(url) or url == "",
       do: {:error, :missing_authorization_url}

  defp build_authorization(%AuthProvider{} = provider, resume_params, opts) do
    redirect_uri =
      Keyword.get(opts, :redirect_uri, WebOrigins.api_url("/auth/#{provider.slug}/callback"))

    {code_verifier, code_challenge} = pkce_pair()
    nonce = random_token(16)

    state =
      OAuthStateStore.put(%{
        "purpose" => @state_purpose,
        "provider_id" => provider.id,
        "provider_slug" => provider.slug,
        "code_verifier" => code_verifier,
        "nonce" => nonce,
        "redirect_uri" => redirect_uri,
        "resume_params" => resume_params
      })

    authorization_url =
      put_query(provider.authorization_url, %{
        "response_type" => "code",
        "client_id" => provider.client_id,
        "redirect_uri" => redirect_uri,
        "scope" => Enum.join(provider.scopes || [], " "),
        "state" => state,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256",
        "nonce" => nonce
      })

    {:ok, %{authorization_url: authorization_url, state: state}}
  end

  defp validate_resume_params(%{"return_to" => return_to} = resume_params)
       when is_binary(return_to) do
    if local_path?(return_to) do
      {:ok, resume_params}
    else
      {:error, :invalid_return_to}
    end
  end

  defp validate_resume_params(resume_params), do: {:ok, resume_params}

  defp local_path?(path) do
    uri = URI.parse(path)

    uri.scheme == nil and uri.host == nil and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//")
  end

  defp ensure_provider_enabled(%AuthProvider{enabled: true}), do: :ok
  defp ensure_provider_enabled(%AuthProvider{enabled: false}), do: {:error, :provider_disabled}

  defp pop_state(state) do
    case OAuthStateStore.pop(state) do
      {:ok, attrs} -> {:ok, attrs}
      :error -> {:error, :invalid_state}
    end
  end

  defp validate_state(provider, %{
         "purpose" => @state_purpose,
         "provider_id" => provider_id,
         "provider_slug" => provider_slug
       }) do
    if provider_id == provider.id and provider_slug == provider.slug do
      :ok
    else
      {:error, :provider_mismatch}
    end
  end

  defp validate_state(_provider, _state_attrs), do: {:error, :invalid_state}

  defp exchange_code(provider, code, state_attrs, client_secret, opts) do
    with :ok <- validate_url(provider.token_url, :missing_token_url) do
      do_exchange_code(provider, code, state_attrs, client_secret, opts)
    end
  end

  defp do_exchange_code(provider, code, state_attrs, client_secret, opts) do
    form = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => Map.get(state_attrs, "redirect_uri"),
      "client_id" => provider.client_id,
      "client_secret" => client_secret,
      "code_verifier" => Map.get(state_attrs, "code_verifier")
    }

    provider.token_url
    |> Req.post(
      Keyword.merge(req_options(opts), form: form, receive_timeout: 15_000, retry: false)
    )
    |> decode_response(:token_exchange_failed)
  end

  defp token_claims(_provider, %{"id_token" => id_token}, _state_attrs, _opts)
       when not is_binary(id_token) or id_token == "",
       do: {:error, :missing_id_token}

  defp token_claims(provider, %{"id_token" => id_token}, state_attrs, opts) do
    with {:ok, jwks} <- fetch_jwks(provider, opts),
         {:ok, claims} <- verify_id_token(id_token, jwks),
         :ok <- validate_id_token_claims(provider, state_attrs, claims) do
      {:ok, claims}
    end
  end

  defp token_claims(%AuthProvider{kind: "oauth2"} = provider, token_response, _state_attrs, opts) do
    with {:ok, access_token} <- fetch_access_token(token_response),
         {:ok, userinfo} <- fetch_userinfo(provider, access_token, opts),
         {:ok, claims} <- normalize_userinfo_claims(userinfo) do
      {:ok, claims}
    end
  end

  defp token_claims(_provider, _token_response, _state_attrs, _opts),
    do: {:error, :missing_id_token}

  defp fetch_jwks(%AuthProvider{jwks_uri: jwks_uri}, _opts)
       when not is_binary(jwks_uri) or jwks_uri == "",
       do: {:error, {:invalid_id_token, :jwks}}

  defp fetch_jwks(provider, opts) do
    provider.jwks_uri
    |> Req.get(Keyword.merge(req_options(opts), receive_timeout: 15_000, retry: false))
    |> decode_response({:invalid_id_token, :jwks})
  end

  defp verify_id_token(id_token, %{"keys" => keys}) when is_list(keys) do
    with {:ok, %{"kid" => kid}} <- id_token_header(id_token),
         %{} = jwk_map <- Enum.find(keys, &(Map.get(&1, "kid") == kid)),
         {:ok, claims} <- verify_id_token_with_key(id_token, jwk_map) do
      {:ok, claims}
    else
      _invalid -> {:error, {:invalid_id_token, :signature}}
    end
  end

  defp verify_id_token(_id_token, _jwks), do: {:error, {:invalid_id_token, :jwks}}

  defp id_token_header(id_token) do
    id_token
    |> String.split(".", parts: 3)
    |> case do
      [encoded_header, _claims, _signature] -> decode_jwt_part(encoded_header)
      _invalid -> {:error, :invalid_header}
    end
  end

  defp decode_jwt_part(encoded_part) do
    with {:ok, json} <- Base.url_decode64(encoded_part, padding: false),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(json) do
      {:ok, decoded}
    else
      _invalid -> {:error, :invalid_part}
    end
  end

  defp verify_id_token_with_key(id_token, jwk_map) when is_map(jwk_map) do
    jwk = JOSE.JWK.from_map(jwk_map)

    case JOSE.JWT.verify_strict(jwk, ["RS256"], id_token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _invalid -> nil
    end
  rescue
    _error -> nil
  end

  defp validate_id_token_claims(provider, state_attrs, claims) do
    cond do
      not present_string?(provider.issuer) ->
        {:error, {:invalid_id_token, :issuer}}

      claim_value(claims, "iss") != provider.issuer ->
        {:error, {:invalid_id_token, :issuer}}

      not audience_matches?(claims, provider.client_id) ->
        {:error, {:invalid_id_token, :audience}}

      not expires_in_future?(claim_value(claims, "exp")) ->
        {:error, {:invalid_id_token, :expired}}

      claim_value(claims, "nonce") != Map.get(state_attrs, "nonce") ->
        {:error, {:invalid_id_token, :nonce}}

      not present_string?(claim_value(claims, "sub")) ->
        {:error, {:invalid_id_token, :missing_sub}}

      true ->
        :ok
    end
  end

  defp audience_matches?(claims, client_id) do
    case claim_value(claims, "aud") do
      audience when is_binary(audience) ->
        audience == client_id

      audiences when is_list(audiences) ->
        client_id in audiences and authorized_party_matches?(claims, audiences, client_id)

      _audience ->
        false
    end
  end

  defp authorized_party_matches?(claims, audiences, client_id) when length(audiences) > 1 do
    claim_value(claims, "azp") == client_id
  end

  defp authorized_party_matches?(_claims, _audiences, _client_id), do: true

  defp expires_in_future?(exp) when is_integer(exp), do: exp > System.system_time(:second)

  defp expires_in_future?(exp) when is_binary(exp) do
    case Integer.parse(exp) do
      {integer, ""} -> expires_in_future?(integer)
      _invalid -> false
    end
  end

  defp expires_in_future?(_exp), do: false

  defp enforce_email_domain(%AuthProvider{allowed_email_domains: domains}, _claims)
       when domains in [nil, []],
       do: :ok

  defp enforce_email_domain(%AuthProvider{allowed_email_domains: domains}, claims) do
    allowed_domains =
      domains
      |> Enum.map(&normalize_domain/1)
      |> Enum.reject(&is_nil/1)

    email_domain =
      claims
      |> claim_value("email")
      |> email_domain()

    if email_domain in allowed_domains do
      :ok
    else
      {:error, :email_domain_not_allowed}
    end
  end

  defp enforce_verified_email(claims) do
    if present_string?(claim_value(claims, "email")) and
         claim_value(claims, "email_verified") != true do
      {:error, :email_not_verified}
    else
      :ok
    end
  end

  defp fetch_access_token(%{"access_token" => access_token})
       when is_binary(access_token) and access_token != "",
       do: {:ok, access_token}

  defp fetch_access_token(_token_response), do: {:error, :missing_access_token}

  defp fetch_userinfo(%AuthProvider{userinfo_url: userinfo_url}, _access_token, _opts)
       when not is_binary(userinfo_url) or userinfo_url == "",
       do: {:error, :missing_userinfo_url}

  defp fetch_userinfo(provider, access_token, opts) do
    provider.userinfo_url
    |> Req.get(
      Keyword.merge(req_options(opts),
        headers: [{"authorization", "Bearer #{access_token}"}],
        receive_timeout: 15_000,
        retry: false
      )
    )
    |> decode_response(:userinfo_failed)
  end

  defp normalize_userinfo_claims(userinfo) do
    with {:ok, subject} <- userinfo_subject(userinfo) do
      claims =
        userinfo
        |> stringify_keys()
        |> Map.put("sub", subject)

      {:ok, claims}
    end
  end

  defp userinfo_subject(userinfo) do
    case claim_value(userinfo, "sub") || claim_value(userinfo, "id") do
      subject when is_binary(subject) and subject != "" -> {:ok, subject}
      subject when is_integer(subject) -> {:ok, Integer.to_string(subject)}
      subject when is_float(subject) -> {:ok, :erlang.float_to_binary(subject, [:compact])}
      _missing -> {:error, {:missing_claim, "sub"}}
    end
  end

  defp decode_response({:ok, %Req.Response{status: status, body: body}}, error)
       when status in 200..299 do
    decode_body(body, error)
  end

  defp decode_response({:ok, %Req.Response{status: status}}, error) when is_integer(status),
    do: {:error, {error, status}}

  defp decode_response({:error, reason}, error), do: {:error, {error, reason}}

  defp decode_body(body, _error) when is_map(body), do: {:ok, body}

  defp decode_body(body, error) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, {error, :invalid_response}}
      {:error, _reason} -> {:error, {error, :invalid_response}}
    end
  end

  defp decode_body(_body, error), do: {:error, {error, :invalid_response}}

  defp pkce_pair do
    verifier = random_token(32)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  defp put_query(url, params) do
    uri = URI.parse(url)
    existing_query = if is_binary(uri.query), do: URI.decode_query(uri.query), else: %{}

    uri
    |> Map.put(:query, URI.encode_query(Map.merge(existing_query, params)))
    |> URI.to_string()
  end

  defp random_token(bytes) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp req_options(opts) do
    :backplane
    |> Application.get_env(:federated_login_req_options, [])
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
  end

  defp validate_url(url, _error) when is_binary(url) and url != "", do: :ok
  defp validate_url(_url, error), do: {:error, error}

  defp claim_value(claims, key) when is_map(claims) do
    Map.get(claims, key) || Map.get(claims, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(claims, key)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp present_string?(value), do: is_binary(value) and value != ""

  defp email_domain(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] -> normalize_domain(domain)
      _invalid -> nil
    end
  end

  defp email_domain(_email), do: nil

  defp normalize_domain(domain) when is_binary(domain) do
    domain = domain |> String.trim() |> String.downcase()
    if domain == "", do: nil, else: domain
  end

  defp normalize_domain(_domain), do: nil
end
