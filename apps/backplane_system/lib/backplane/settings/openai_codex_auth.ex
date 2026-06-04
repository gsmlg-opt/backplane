defmodule Backplane.Settings.OpenAICodexAuth do
  @moduledoc """
  OpenAI Codex device-code OAuth flow backed by the encrypted credential store.

  This module owns the Codex-specific auth.openai.com deviceauth protocol. It
  returns only login state, account metadata, and safe credential status. Raw
  OAuth tokens are persisted through `Backplane.Settings.Credentials` and are
  never returned from public functions.
  """

  alias Backplane.Repo
  alias Backplane.Settings.{Credential, Credentials, Encryption}

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @device_verification_url "https://auth.openai.com/codex/device"
  @device_callback_url "https://auth.openai.com/deviceauth/callback"
  @default_credential_name "openai-codex"
  @device_ttl_ms 15 * 60 * 1000

  @type device_login :: %{
          required(:login_id) => String.t(),
          required(:device_auth_id) => String.t(),
          required(:verification_url) => String.t(),
          required(:user_code) => String.t(),
          required(:interval_seconds) => pos_integer(),
          required(:expires_at) => integer(),
          required(:status) => :pending
        }

  @type code_result :: %{
          required(:authorization_code) => String.t(),
          required(:code_challenge) => String.t(),
          required(:code_verifier) => String.t(),
          optional(:credential_name) => String.t()
        }

  @doc "Start a Codex device-code login and return the verification URL plus one-time code."
  @spec start_device_login() :: {:ok, device_login()} | {:error, term()}
  def start_device_login do
    case post_json(url(:device_user_code_url), %{"client_id" => @client_id}) do
      {:ok, %{status: 200, body: body}} ->
        parse_device_login(body)

      {:ok, %{status: 404}} ->
        {:error, :device_code_login_disabled}

      {:ok, %{status: status}} ->
        {:error, {:device_code_request_failed, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  @doc "Poll a pending Codex device login once."
  @spec poll_device_login(device_login() | map()) ::
          {:ok, code_result()} | {:pending, map()} | {:expired} | {:error, term()}
  def poll_device_login(%{} = login) do
    with {:ok, device_auth_id} <- required(login, :device_auth_id),
         {:ok, user_code} <- required(login, :user_code) do
      cond do
        expired?(login) ->
          {:expired}

        true ->
          poll_device_token(login, device_auth_id, user_code)
      end
    end
  end

  @doc "Exchange a Codex authorization code for tokens and persist them securely."
  @spec exchange_authorization_code(code_result() | map()) :: {:ok, map()} | {:error, term()}
  def exchange_authorization_code(%{} = code_result) do
    with {:ok, authorization_code} <- required(code_result, :authorization_code),
         {:ok, code_verifier} <- required(code_result, :code_verifier),
         {:ok, tokens} <- request_token_exchange(authorization_code, code_verifier),
         credential_name = credential_name(code_result),
         {:ok, _credential} <- persist_tokens(credential_name, tokens) do
      {:ok, token_state(credential_name, tokens)}
    end
  end

  @doc "Refresh a Codex token set, persist rotated tokens, and return safe account state."
  @spec refresh_tokens(map()) :: {:ok, map()} | {:error, term()}
  def refresh_tokens(%{} = token_set) do
    with {:ok, refresh_token} <- required(token_set, :refresh_token),
         {:ok, refreshed} <- request_refresh(refresh_token),
         credential_name = credential_name(token_set),
         tokens = merge_refreshed_tokens(token_set, refreshed),
         {:ok, _credential} <- persist_tokens(credential_name, tokens) do
      {:ok, token_state(credential_name, tokens)}
    end
  end

  @doc "Revoke a Codex refresh token."
  @spec revoke_tokens(map()) :: :ok | {:error, term()}
  def revoke_tokens(%{} = token_set) do
    with {:ok, refresh_token} <- required(token_set, :refresh_token) do
      body = %{
        "token" => refresh_token,
        "token_type_hint" => "refresh_token",
        "client_id" => @client_id
      }

      case post_json(url(:revoke_url), body) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          {:error, {:revocation_failed, status}}

        {:error, reason} ->
          {:error, {:transport_error, reason}}
      end
    end
  end

  @doc "Read the default Codex credential state, refreshing through the credential store if needed."
  @spec read_token_state() :: {:ok, map()} | {:error, term()}
  def read_token_state do
    case Credentials.fetch(@default_credential_name) do
      {:ok, _access_token} ->
        with {:ok, tokens} <- load_tokens(@default_credential_name) do
          {:ok, token_state(@default_credential_name, tokens)}
        end

      {:error, :not_found} ->
        {:ok, %{status: :unauthenticated}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Revoke and delete the default Codex credential. Local deletion happens even if revoke fails."
  @spec logout() :: {:ok, map()}
  def logout do
    case load_tokens(@default_credential_name) do
      {:ok, tokens} ->
        _ = revoke_tokens(tokens)
        _ = Credentials.delete(@default_credential_name)
        {:ok, %{status: :logged_out}}

      {:error, :not_found} ->
        {:ok, %{status: :logged_out}}

      {:error, _reason} ->
        _ = Credentials.delete(@default_credential_name)
        {:ok, %{status: :logged_out}}
    end
  end

  defp poll_device_token(login, device_auth_id, user_code) do
    case post_json(url(:device_token_url), %{
           "device_auth_id" => device_auth_id,
           "user_code" => user_code
         }) do
      {:ok, %{status: 200, body: body}} ->
        parse_code_result(body)

      {:ok, %{status: status}} when status in [403, 404] ->
        {:pending, login}

      {:ok, %{status: status}} ->
        {:error, {:poll_failed, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp request_token_exchange(authorization_code, code_verifier) do
    body = %{
      "grant_type" => "authorization_code",
      "code" => authorization_code,
      "redirect_uri" => @device_callback_url,
      "client_id" => @client_id,
      "code_verifier" => code_verifier
    }

    case post_form(url(:token_url), body) do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body)

      {:ok, %{status: status}} ->
        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp request_refresh(refresh_token) do
    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => @client_id
    }

    case post_form(url(:token_url), body) do
      {:ok, %{status: 200, body: body}} ->
        parse_token_response(body, refresh_token)

      {:ok, %{status: _status, body: %{"error" => "refresh_token_reused"}}} ->
        {:error, :refresh_token_reused}

      {:ok, %{status: status}} ->
        {:error, {:refresh_failed, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp parse_device_login(%{} = body) do
    with {:ok, device_auth_id} <- required(body, :device_auth_id),
         {:ok, user_code} <- first_present(body, [:user_code, :usercode]) do
      interval_seconds = body |> get_any(:interval) |> parse_positive_integer(5)
      now_ms = System.system_time(:millisecond)

      {:ok,
       %{
         login_id: random_id(),
         device_auth_id: device_auth_id,
         verification_url: @device_verification_url,
         user_code: user_code,
         interval_seconds: interval_seconds,
         expires_at: now_ms + @device_ttl_ms,
         status: :pending
       }}
    end
  end

  defp parse_code_result(%{} = body) do
    with {:ok, authorization_code} <- required(body, :authorization_code),
         {:ok, code_challenge} <- required(body, :code_challenge),
         {:ok, code_verifier} <- required(body, :code_verifier) do
      {:ok,
       %{
         authorization_code: authorization_code,
         code_challenge: code_challenge,
         code_verifier: code_verifier
       }}
    end
  end

  defp parse_token_response(body, fallback_refresh_token \\ nil)

  defp parse_token_response(%{} = body, fallback_refresh_token) do
    with {:ok, access_token} <- required(body, :access_token),
         {:ok, id_token} <- required(body, :id_token),
         refresh_token = get_any(body, :refresh_token) || fallback_refresh_token,
         true <- is_binary(refresh_token) and refresh_token != "" do
      claims = merge_claims(decode_jwt_claims(id_token), decode_jwt_claims(access_token))
      expires_at = token_expires_at(body, claims)

      tokens =
        %{
          "type" => "codex_device_oauth",
          "auth_mode" => "chatgpt",
          "id_token" => id_token,
          "access_token" => access_token,
          "refresh_token" => refresh_token,
          "expires_at" => expires_at,
          "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
        |> maybe_put("account_id", first_claim(claims, ["chatgpt_account_id", "account_id"]))
        |> maybe_put("plan_type", first_claim(claims, ["chatgpt_plan_type", "plan_type"]))
        |> maybe_put("email", claims["email"])
        |> maybe_put("organization_id", claims["organization_id"])
        |> maybe_put("project_id", claims["project_id"])

      {:ok, tokens}
    else
      false -> {:error, :missing_refresh_token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_tokens(credential_name, tokens) do
    Credentials.store_device_token(credential_name, "openai_oauth", tokens, token_hints(tokens))
  end

  defp load_tokens(credential_name) do
    case Repo.get_by(Credential, name: credential_name) do
      nil ->
        {:error, :not_found}

      %Credential{encrypted_value: encrypted} ->
        with {:ok, raw} <- Encryption.decrypt(encrypted),
             {:ok, tokens} <- Jason.decode(raw) do
          {:ok, tokens}
        end
    end
  end

  defp token_hints(tokens) do
    %{"auth_mode" => "chatgpt"}
    |> maybe_put("account_id", get_any(tokens, :account_id))
    |> maybe_put("plan_type", get_any(tokens, :plan_type))
    |> maybe_put("email", get_any(tokens, :email))
  end

  defp token_state(credential_name, tokens) do
    %{
      status: :authenticated,
      credential_name: credential_name,
      account_id: get_any(tokens, :account_id),
      plan_type: get_any(tokens, :plan_type),
      email: get_any(tokens, :email),
      organization_id: get_any(tokens, :organization_id),
      project_id: get_any(tokens, :project_id),
      expires_at: get_any(tokens, :expires_at)
    }
  end

  defp merge_refreshed_tokens(token_set, refreshed) do
    base =
      token_set
      |> stringify_keys()
      |> Map.take([
        "type",
        "auth_mode",
        "account_id",
        "plan_type",
        "email",
        "organization_id",
        "project_id"
      ])

    refreshed
    |> Map.merge(base, fn _key, refreshed_value, old_value -> refreshed_value || old_value end)
    |> Map.put("type", "codex_device_oauth")
    |> Map.put("auth_mode", "chatgpt")
  end

  defp expired?(login) do
    expires_at = get_any(login, :expires_at) || 0
    System.system_time(:millisecond) >= expires_at
  end

  defp token_expires_at(body, claims) do
    case parse_positive_integer(get_any(body, :expires_in), nil) do
      nil ->
        case parse_positive_integer(claims["exp"], nil) do
          nil -> System.system_time(:millisecond) + 3600 * 1000
          exp_seconds -> exp_seconds * 1000
        end

      expires_in_seconds ->
        System.system_time(:millisecond) + expires_in_seconds * 1000
    end
  end

  defp decode_jwt_claims(token) when is_binary(token) do
    with [_header, payload | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      claims
    else
      _ -> %{}
    end
  end

  defp decode_jwt_claims(_), do: %{}

  defp merge_claims(id_claims, access_claims), do: Map.merge(access_claims, id_claims)

  defp first_claim(claims, keys) do
    Enum.find_value(keys, &claims[&1])
  end

  defp credential_name(map) do
    case get_any(map, :credential_name) do
      name when is_binary(name) and name != "" -> name
      _ -> @default_credential_name
    end
  end

  defp required(map, key) do
    case get_any(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case get_any(map, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _ -> nil
      end
    end) || {:error, {:missing_field, hd(keys)}}
  end

  defp get_any(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_any(map, key), do: Map.get(map, key)

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp post_json(url, body) do
    Req.post(url, Keyword.merge(req_options(url), json: body, receive_timeout: 15_000))
  end

  defp post_form(url, body) do
    Req.post(url, Keyword.merge(req_options(url), form: body, receive_timeout: 15_000))
  end

  defp req_options(url) do
    config = Application.get_env(:backplane, __MODULE__, [])

    case Keyword.fetch(config, :req_options) do
      {:ok, opts} -> opts
      :error -> default_req_options(url)
    end
  end

  defp default_req_options(url) do
    case proxy_connect_options(url) do
      [] -> [inet6: true]
      connect_options -> [connect_options: connect_options]
    end
  end

  defp proxy_connect_options(url) do
    uri = URI.parse(url)

    if proxy_bypassed?(uri.host) do
      []
    else
      uri.scheme
      |> proxy_url_from_env()
      |> proxy_connect_options_from_url()
    end
  end

  defp proxy_url_from_env("https") do
    env("HTTPS_PROXY") || env("https_proxy") ||
      env("HTTP_PROXY") || env("http_proxy") ||
      env("ALL_PROXY") || env("all_proxy")
  end

  defp proxy_url_from_env("http") do
    env("HTTP_PROXY") || env("http_proxy") ||
      env("ALL_PROXY") || env("all_proxy")
  end

  defp proxy_url_from_env(_scheme), do: nil

  defp proxy_connect_options_from_url(nil), do: []

  defp proxy_connect_options_from_url(proxy_url) do
    uri = URI.parse(proxy_url)
    scheme = proxy_scheme(uri.scheme)

    cond do
      is_nil(scheme) or is_nil(uri.host) ->
        []

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        [
          proxy: {scheme, uri.host, uri.port || default_proxy_port(scheme), []},
          proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64(uri.userinfo)}]
        ]

      true ->
        [proxy: {scheme, uri.host, uri.port || default_proxy_port(scheme), []}]
    end
  end

  defp proxy_scheme("http"), do: :http
  defp proxy_scheme("https"), do: :https
  defp proxy_scheme(_), do: nil

  defp default_proxy_port(:http), do: 80
  defp default_proxy_port(:https), do: 443

  defp proxy_bypassed?(nil), do: false

  defp proxy_bypassed?(host) do
    no_proxy = env("NO_PROXY") || env("no_proxy")
    no_proxy && no_proxy_match?(String.downcase(host), no_proxy)
  end

  defp no_proxy_match?(host, no_proxy) do
    no_proxy
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&no_proxy_entry_match?(host, String.downcase(&1)))
  end

  defp no_proxy_entry_match?(_host, "*"), do: true
  defp no_proxy_entry_match?(_host, ""), do: false

  defp no_proxy_entry_match?(host, "*." <> domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp no_proxy_entry_match?(host, "." <> domain) do
    host == domain or String.ends_with?(host, "." <> domain)
  end

  defp no_proxy_entry_match?(host, entry), do: host == entry

  defp env(name) do
    name
    |> System.get_env()
    |> normalize_optional_string()
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp url(key) do
    :backplane
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default_url(key))
  end

  defp default_url(:device_user_code_url),
    do: "https://auth.openai.com/api/accounts/deviceauth/usercode"

  defp default_url(:device_token_url),
    do: "https://auth.openai.com/api/accounts/deviceauth/token"

  defp default_url(:token_url), do: "https://auth.openai.com/oauth/token"
  defp default_url(:revoke_url), do: "https://auth.openai.com/oauth/revoke"
end
