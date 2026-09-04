defmodule Relayixir.Proxy.EnvironmentProxy do
  @moduledoc false

  @type connect_option ::
          {:proxy, {:http, String.t(), :inet.port_number(), keyword()}}
          | {:proxy_headers, [{String.t(), String.t()}]}

  @spec connect_options(:http | :https, String.t() | nil, :inet.port_number(), map()) ::
          [connect_option()]
  def connect_options(scheme, host, _port, env \\ System.get_env()) do
    if bypassed?(host, env) do
      []
    else
      scheme
      |> proxy_url(env)
      |> options_from_url(scheme)
    end
  end

  defp proxy_url(:https, env) do
    env_value(env, "HTTPS_PROXY") || env_value(env, "https_proxy") ||
      env_value(env, "HTTP_PROXY") || env_value(env, "http_proxy") ||
      env_value(env, "ALL_PROXY") || env_value(env, "all_proxy")
  end

  defp proxy_url(:http, env) do
    env_value(env, "HTTP_PROXY") || env_value(env, "http_proxy") ||
      env_value(env, "ALL_PROXY") || env_value(env, "all_proxy")
  end

  defp proxy_url(_scheme, _env), do: nil

  defp options_from_url(nil, _target_scheme), do: []

  defp options_from_url(proxy_url, target_scheme) do
    uri = URI.parse(proxy_url)

    with proxy_scheme when not is_nil(proxy_scheme) <- proxy_scheme(uri.scheme, target_scheme),
         host when is_binary(host) and host != "" <- uri.host do
      proxy = {proxy_scheme, host, uri.port || default_port(proxy_scheme), []}

      case normalize(uri.userinfo) do
        nil ->
          [proxy: proxy]

        userinfo ->
          [
            proxy: proxy,
            proxy_headers: [
              {"proxy-authorization", "Basic " <> Base.encode64(URI.decode(userinfo))}
            ]
          ]
      end
    else
      _ -> []
    end
  end

  defp proxy_scheme("http", _target_scheme), do: :http
  defp proxy_scheme("https", :http), do: :https
  defp proxy_scheme(_proxy_scheme, _target_scheme), do: nil

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  defp bypassed?(nil, _env), do: false

  defp bypassed?(host, env) do
    case env_value(env, "NO_PROXY") || env_value(env, "no_proxy") do
      nil -> false
      no_proxy -> no_proxy_match?(String.downcase(host), no_proxy)
    end
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

  defp env_value(env, name), do: env |> Map.get(name) |> normalize()

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize(_value), do: nil
end
