defmodule Backplane.HTTPClient.Proxy do
  @moduledoc """
  Resolves an `HTTP.fetch/2` proxy from `HTTP(S)_PROXY`, `ALL_PROXY` and
  `NO_PROXY` environment variables.
  """

  @type t :: {:http | :https, String.t(), :inet.port_number(), keyword()}

  @doc "Returns the proxy for reaching `url`, or `nil` when none applies."
  @spec from_env(String.t() | URI.t()) :: t() | nil
  def from_env(url) do
    uri = URI.parse(url)

    if proxy_bypassed?(uri.host) do
      nil
    else
      uri.scheme
      |> proxy_url_from_env()
      |> proxy_from_url()
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

  defp proxy_from_url(nil), do: nil

  defp proxy_from_url(proxy_url) do
    uri = URI.parse(proxy_url)
    scheme = proxy_scheme(uri.scheme)

    cond do
      is_nil(scheme) or is_nil(uri.host) ->
        nil

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        auth = {"proxy-authorization", "Basic " <> Base.encode64(uri.userinfo)}
        {scheme, uri.host, uri.port || default_proxy_port(scheme), [headers: [auth]]}

      true ->
        {scheme, uri.host, uri.port || default_proxy_port(scheme), []}
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
