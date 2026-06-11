defmodule Backplane.Settings.OAuthRefresher do
  @moduledoc """
  OAuth refresh-token exchange for AI plan credential formats.

  Supported vendors:
  - `:anthropic_oauth` — Claude Plan (platform.claude.com)
  - `:openai_oauth`   — OpenAI Codex (auth.openai.com)
  - `:google_oauth`   — Google AI (oauth2.googleapis.com)
  - `:xai_oauth`      — xAI Grok (auth.x.ai)

  Pure function. Does not touch the DB or cache. The caller (`Credentials`)
  persists rotated tokens.
  """

  require Logger

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @anthropic_token_url "https://platform.claude.com/v1/oauth/token"
  @anthropic_oauth_user_agent "claude-cli/2.1.165 (external, cli)"
  @legacy_anthropic_token_urls [
    "https://console.anthropic.com/v1/oauth/token",
    "https://api.anthropic.com/api/oauth/claude_cli/create_api_key"
  ]
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @google_antigravity_client_id "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
  @xai_client_id "b1a00492-073a-47ea-816f-4c329264a828"

  @type vendor :: :anthropic_oauth | :openai_oauth | :google_oauth | :xai_oauth
  @type refreshed :: %{
          required(:access_token) => String.t(),
          required(:refresh_token) => String.t(),
          required(:expires_at) => integer(),
          optional(:id_token) => String.t()
        }

  @spec anthropic_oauth_token_headers() :: [{String.t(), String.t()}]
  def anthropic_oauth_token_headers do
    [
      {"User-Agent", cfg(:anthropic_user_agent) || @anthropic_oauth_user_agent},
      {"x-app", "cli"},
      {"anthropic-client-platform", "claude_code_cli"}
    ]
  end

  @spec request_options(String.t()) :: keyword()
  def request_options(url) do
    case Keyword.fetch(Application.get_env(:backplane, __MODULE__, []), :req_options) do
      {:ok, opts} -> opts
      :error -> default_req_options(url)
    end
  end

  @spec refresh(vendor(), String.t(), keyword()) :: {:ok, refreshed()} | {:error, term()}
  def refresh(vendor, refresh_token, opts \\ [])

  def refresh(:anthropic_oauth, refresh_token, _opts) when is_binary(refresh_token) do
    do_refresh(
      url(:anthropic_token_url),
      :json,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @anthropic_client_id
      },
      anthropic_oauth_token_headers()
    )
  end

  def refresh(:openai_oauth, refresh_token, _opts) when is_binary(refresh_token) do
    do_refresh(
      url(:openai_token_url),
      :form,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @openai_client_id
      }
    )
  end

  def refresh(:google_oauth, refresh_token, opts) when is_binary(refresh_token) do
    with {:ok, body} <- google_refresh_body(refresh_token, opts) do
      do_refresh(
        url(:google_token_url),
        :form,
        body
      )
    end
  end

  def refresh(:xai_oauth, refresh_token, opts) when is_binary(refresh_token) do
    do_refresh(
      url(:xai_token_url),
      :form,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => xai_client_id(opts)
      }
    )
  end

  defp do_refresh(url, encoding, body, headers \\ []) do
    req_opts =
      request_options(url)
      |> Keyword.merge(req_body_options(encoding, body, headers))

    case Req.post(url, req_opts) do
      {:ok, %{status: 200, body: %{"access_token" => access} = resp}} ->
        expires_in = resp["expires_in"] || 3600
        refresh = resp["refresh_token"] || body["refresh_token"]
        expires_at = System.system_time(:millisecond) + expires_in * 1000

        result = %{access_token: access, refresh_token: refresh, expires_at: expires_at}

        result =
          if resp["id_token"], do: Map.put(result, :id_token, resp["id_token"]), else: result

        {:ok, result}

      {:ok, %{status: status}} ->
        Logger.warning("OAuth refresh failed: status=#{status}")
        {:error, {:refresh_failed, status}}

      {:error, reason} ->
        Logger.warning("OAuth refresh transport error: #{inspect(reason)}")
        {:error, {:refresh_error, reason}}
    end
  end

  defp req_body_options(encoding, body, []), do: [{encoding, body}, {:receive_timeout, 10_000}]

  defp req_body_options(encoding, body, headers) do
    [{encoding, body}, {:headers, headers}, {:receive_timeout, 10_000}]
  end

  defp url(:anthropic_token_url) do
    :anthropic_token_url
    |> cfg()
    |> normalize_anthropic_token_url()
  end

  defp url(key) do
    cfg(key) || default_url(key)
  end

  defp normalize_anthropic_token_url(url) when url in @legacy_anthropic_token_urls,
    do: @anthropic_token_url

  defp normalize_anthropic_token_url(url), do: url || @anthropic_token_url

  defp google_refresh_body(refresh_token, opts) do
    client_id = google_client_id(opts)
    client_secret = option_or_config(opts, :google_client_secret, "GOOGLE_OAUTH_CLIENT_SECRET")

    if is_nil(client_id) do
      {:error, :missing_google_oauth_client_id}
    else
      body =
        %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh_token,
          "client_id" => client_id
        }
        |> maybe_put_body("client_secret", client_secret)

      {:ok, body}
    end
  end

  defp google_client_id(opts) do
    option_or_config(opts, :google_client_id, "GOOGLE_OAUTH_CLIENT_ID") ||
      @google_antigravity_client_id
  end

  defp xai_client_id(opts) do
    option_or_config(opts, :xai_client_id, "XAI_OAUTH_CLIENT_ID") || @xai_client_id
  end

  defp maybe_put_body(body, _key, nil), do: body
  defp maybe_put_body(body, _key, ""), do: body
  defp maybe_put_body(body, key, value), do: Map.put(body, key, value)

  defp option_or_config(opts, key, env_key) do
    [
      Keyword.get(opts, key),
      cfg(key),
      System.get_env(env_key)
    ]
    |> Enum.find_value(&normalize_optional_string/1)
  end

  defp cfg(key) do
    :backplane
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
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

  defp default_url(:anthropic_token_url), do: @anthropic_token_url
  defp default_url(:openai_token_url), do: "https://auth.openai.com/oauth/token"
  defp default_url(:google_token_url), do: "https://oauth2.googleapis.com/token"
  defp default_url(:xai_token_url), do: "https://auth.x.ai/oauth2/token"
end
