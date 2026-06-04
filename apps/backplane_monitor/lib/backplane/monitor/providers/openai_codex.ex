defmodule Backplane.Monitor.Providers.OpenAICodex do
  @moduledoc """
  Fetches OpenAI Codex plan usage through the ChatGPT backend usage endpoint.

  This intentionally avoids the Codex CLI/App Server and wraps the source-derived
  backend endpoint behind a provider boundary so the caller only sees normalized
  usage data.
  """

  @default_url "https://chatgpt.com/backend-api/wham/usage"
  @default_user_agent "codex-cli"
  @default_receive_timeout 15_000

  @doc "Fetch OpenAI Codex usage with an OAuth access token and plan config."
  @spec fetch(String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def fetch(access_token, config \\ %{}) do
    token_state = %{
      "access_token" => access_token,
      "chatgpt_account_id" => account_id(config)
    }

    get_current_usage(token_state, config)
  end

  @doc "Fetch current usage from a token-state map."
  @spec get_current_usage(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_current_usage(token_state \\ %{}, config \\ %{})

  def get_current_usage(token_state, config) when is_map(token_state) and is_map(config) do
    with {:ok, access_token} <-
           required_string(token_state, "access_token", :missing_access_token),
         {:ok, chatgpt_account_id} <-
           required_string(token_state, "chatgpt_account_id", :missing_chatgpt_account_id) do
      request_usage(access_token, chatgpt_account_id, config)
    end
  end

  @doc "Bang variant of get_current_usage/2."
  @spec get_current_usage!(map(), map()) :: map()
  def get_current_usage!(token_state, config \\ %{}) do
    case get_current_usage(token_state, config) do
      {:ok, usage} ->
        usage

      {:error, reason} ->
        raise RuntimeError, "OpenAI Codex usage fetch failed: #{inspect(reason)}"
    end
  end

  @doc "Normalize the raw ChatGPT/Codex usage response."
  @spec normalize_usage_response(map()) :: map() | {:error, :invalid_usage_response}
  def normalize_usage_response(%{} = raw) do
    case value(raw, "plan_type") do
      plan_type when is_binary(plan_type) and plan_type != "" ->
        %{
          provider: "openai_codex",
          status: "ok",
          plan_type: plan_type,
          limits: normalized_limits(raw)
        }

      _ ->
        {:error, :invalid_usage_response}
    end
  end

  def normalize_usage_response(_), do: {:error, :invalid_usage_response}

  defp request_usage(access_token, chatgpt_account_id, config) do
    url = config_value(config, "api_url") || @default_url

    case Req.get(
           url,
           [
             headers: request_headers(access_token, chatgpt_account_id, config),
             receive_timeout: receive_timeout(config),
             retry: false
           ] ++ req_options(url)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case normalize_usage_response(body) do
          {:error, reason} -> {:error, reason}
          normalized -> {:ok, normalized}
        end

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 429} = response} ->
        {:error, {:rate_limited, retry_after(response)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp request_headers(access_token, chatgpt_account_id, config) do
    [
      {"authorization", "Bearer #{access_token}"},
      {"chatgpt-account-id", chatgpt_account_id},
      {"user-agent", config_value(config, "user_agent") || @default_user_agent},
      {"accept", "application/json"}
    ]
    |> maybe_add_fedramp_header(config)
  end

  defp maybe_add_fedramp_header(headers, config) do
    if truthy?(config_value(config, "is_fedramp_account")) do
      [{"x-openai-fedramp", "true"} | headers]
    else
      headers
    end
  end

  defp normalized_limits(raw) do
    main = {"codex", main_limit(raw)}

    additional =
      raw
      |> value("additional_rate_limits")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.with_index(1)
      |> Enum.map(&additional_limit/1)

    Map.new([main | additional])
  end

  defp main_limit(raw) do
    rate_limit = value(raw, "rate_limit")

    %{
      limit_id: "codex",
      limit_name: nil,
      primary: normalize_window(value(rate_limit, "primary_window")),
      secondary: normalize_window(value(rate_limit, "secondary_window")),
      credits: normalize_credits(value(raw, "credits")),
      rate_limit_reached_type: normalize_reached_type(value(raw, "rate_limit_reached_type"))
    }
  end

  defp additional_limit({limit, index}) do
    limit_id =
      value(limit, "metered_feature") ||
        value(limit, "limit_name") ||
        "additional_#{index}"

    rate_limit = value(limit, "rate_limit")

    {limit_id,
     %{
       limit_id: limit_id,
       limit_name: value(limit, "limit_name"),
       primary: normalize_window(value(rate_limit, "primary_window")),
       secondary: normalize_window(value(rate_limit, "secondary_window")),
       credits: nil,
       rate_limit_reached_type: nil
     }}
  end

  defp normalize_window(nil), do: nil

  defp normalize_window(%{} = window) do
    %{
      used_percent: number_or_nil(value(window, "used_percent")),
      window_duration_mins: window_duration_mins(value(window, "limit_window_seconds")),
      resets_at: number_or_nil(value(window, "reset_at"))
    }
  end

  defp normalize_window(_), do: nil

  defp normalize_credits(nil), do: nil

  defp normalize_credits(%{} = credits) do
    %{
      has_credits: value(credits, "has_credits"),
      unlimited: value(credits, "unlimited"),
      balance: value(credits, "balance")
    }
  end

  defp normalize_credits(_), do: nil

  defp normalize_reached_type(%{} = value), do: value(value, "type")
  defp normalize_reached_type(value) when is_binary(value), do: value
  defp normalize_reached_type(_), do: nil

  defp window_duration_mins(value) do
    case number_or_nil(value) do
      nil -> nil
      seconds -> ceil(seconds / 60)
    end
  end

  defp required_string(map, key, reason) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, reason}, else: {:ok, value}

      _ ->
        {:error, reason}
    end
  end

  defp account_id(config) do
    config_value(config, "chatgpt_account_id") || config_value(config, "account_id")
  end

  defp config_value(map, key) when is_map(map) do
    case value(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        value
    end
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      atom_key = String.to_atom(key)
      Map.get(map, atom_key)
    end
  end

  defp value(_, _), do: nil

  defp number_or_nil(value) when is_integer(value) or is_float(value), do: value

  defp number_or_nil(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp number_or_nil(_), do: nil

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp receive_timeout(config) do
    case config_value(config, "receive_timeout_ms") do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      timeout when is_binary(timeout) -> parse_positive_integer(timeout, @default_receive_timeout)
      _ -> @default_receive_timeout
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp retry_after(%Req.Response{} = response) do
    response
    |> response_header("retry-after")
    |> parse_retry_after()
  end

  defp response_header(%Req.Response{headers: headers}, name) do
    normalized = String.downcase(name)

    Enum.find_value(headers || [], fn
      {key, [value | _]} when is_binary(value) ->
        if String.downcase(to_string(key)) == normalized, do: value

      {key, value} when is_binary(value) ->
        if String.downcase(to_string(key)) == normalized, do: value

      _ ->
        nil
    end)
  end

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp req_options(url) do
    case Application.fetch_env(:backplane, :openai_codex_monitor_req_options) do
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
end
