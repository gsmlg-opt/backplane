defmodule Backplane.Monitor.Providers.ClaudeCode do
  @moduledoc """
  Fetches Claude Code usage from Anthropic OAuth or a stored JavaScript fetch script.

  OAuth credentials call Anthropic's Claude Code usage endpoint directly.
  Script credentials are kept as a fallback and are expected to contain
  JavaScript that awaits a fetch response, awaits `response.json()`, and
  returns the decoded usage payload.
  """

  @provider "claude_code"
  @default_usage_url "https://api.anthropic.com/api/oauth/usage"
  @anthropic_beta "oauth-2025-04-20"
  @default_receive_timeout 15_000
  @default_timeout 30_000
  @proxy_env_vars ~w(
    HTTP_PROXY
    HTTPS_PROXY
    ALL_PROXY
    NO_PROXY
    http_proxy
    https_proxy
    all_proxy
    no_proxy
  )

  @doc "Run a Claude Code usage script through Denox and return the decoded payload."
  @spec fetch(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch(script, config \\ %{}) when is_binary(script) and is_map(config) do
    timeout = timeout_ms(config)

    with {:ok, runtime} <- runtime(),
         {:ok, usage} <- run_script(runtime, script, config, timeout) do
      {:ok, %{provider: @provider, usage: usage}}
    end
  end

  @doc "Fetch Claude Code usage with an Anthropic OAuth access token."
  @spec fetch_oauth(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch_oauth(access_token, config \\ %{}) when is_binary(access_token) and is_map(config) do
    access_token = String.trim(access_token)

    if access_token == "" do
      {:error, :missing_access_token}
    else
      request_oauth_usage(access_token, config)
    end
  end

  defp request_oauth_usage(access_token, config) do
    url = config_value(config, "api_url") || @default_usage_url

    case Req.get(
           url,
           [
             headers: oauth_headers(access_token),
             receive_timeout: @default_receive_timeout,
             retry: false
           ] ++ req_options(url)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, %{provider: @provider, usage: body}}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :invalid_usage_response}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp oauth_headers(access_token) do
    [
      {"authorization", "Bearer #{access_token}"},
      {"anthropic-beta", @anthropic_beta},
      {"accept", "application/json"}
    ]
  end

  defp runtime do
    case Denox.runtime(permissions: [allow_net: true, allow_env: @proxy_env_vars]) do
      {:ok, runtime} -> {:ok, runtime}
      {:error, reason} -> {:error, {:script_runtime_failed, reason}}
    end
  end

  defp run_script(runtime, script, config, timeout) do
    task = Denox.eval_async_decode(runtime, script_module(script, config))

    try do
      case Task.await(task, timeout) do
        {:ok, usage} -> {:ok, usage}
        {:error, reason} -> {:error, {:script_failed, reason}}
      end
    catch
      :exit, {:timeout, _} -> {:error, {:script_failed, :timeout}}
      :exit, reason -> {:error, {:script_failed, reason}}
    end
  end

  defp script_module(script, config) do
    config_json = Jason.encode!(config)
    script = String.trim(script)

    cond do
      String.contains?(script, "export default") ->
        """
        const config = #{config_json};
        const planConfig = config;
        #{script}
        """

      bare_fetch_script?(script) ->
        """
        const config = #{config_json};
        const planConfig = config;
        const response = await (#{strip_trailing_semicolon(script)});
        const responseForDiagnostics = response.clone();
        let usage;

        try {
          usage = await response.json();
        } catch (error) {
          const contentType = response.headers.get("content-type") || "unknown";
          const body = await responseForDiagnostics.text();
          throw new Error(`Expected JSON response but got status ${response.status} ${contentType}: ${body.slice(0, 200)}`);
        }

        export default usage;
        """

      true ->
        """
        const config = #{config_json};
        const planConfig = config;

        export default await (async () => {
        #{script}
        })();
        """
    end
  end

  defp bare_fetch_script?(script) do
    String.starts_with?(script, "fetch(") and not String.contains?(script, "return")
  end

  defp strip_trailing_semicolon(script) do
    script
    |> String.trim()
    |> String.trim_trailing(";")
  end

  defp timeout_ms(%{"timeout_ms" => timeout}) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp timeout_ms(%{"timeout_ms" => timeout}) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> @default_timeout
    end
  end

  defp timeout_ms(_config), do: @default_timeout

  defp config_value(map, key) when is_map(map) and is_binary(key) do
    map
    |> Map.get(key, Map.get(map, String.to_atom(key)))
    |> normalize_optional_string()
  end

  defp req_options(url) do
    case Application.fetch_env(:backplane, :claude_code_monitor_req_options) do
      {:ok, opts} -> opts
      :error -> default_req_options(url)
    end
  end

  defp default_req_options(url) do
    case proxy_connect_options(url) do
      [] -> []
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

  defp normalize_optional_string(value), do: value
end
