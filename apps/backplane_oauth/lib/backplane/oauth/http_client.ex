defmodule Backplane.Oauth.HttpClient do
  @moduledoc false

  alias Backplane.Oauth.Config

  @receive_timeout 15_000

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @spec get(
          url :: String.t(),
          trusted_authorities :: String.t(),
          trusted_hosts :: list(String.t())
        ) ::
          {:ok, response()} | {:error, term()}
  def get(url, trusted_authorities \\ "", trusted_hosts \\ []) do
    trusted_hosts = add_issuer_host(trusted_hosts)

    get_with_trust(url, trusted_authorities, trusted_hosts)
  end

  defp get_with_trust(_url, "", []),
    do: {:error, "Client must configure trusted hosts or authorities for outbound requests."}

  defp get_with_trust(url, trusted_authorities, trusted_hosts) do
    with {:ok, trusted_hosts} <- validate_trusted_hosts(url, trusted_hosts),
         {:ok, trusted_authorities} <- validate_trusted_authorities(trusted_authorities) do
      trusted_get(url, trusted_hosts, trusted_authorities)
    end
  end

  defp add_issuer_host(trusted_hosts) when is_list(trusted_hosts) do
    case URI.parse(Config.issuer()) do
      %URI{host: host} when is_binary(host) -> [host | trusted_hosts]
      _issuer -> trusted_hosts
    end
  rescue
    _error -> trusted_hosts
  end

  defp add_issuer_host(trusted_hosts), do: trusted_hosts

  defp validate_trusted_hosts(_url, []),
    do: {:ok, []}

  defp validate_trusted_hosts(url, trusted_hosts) when is_list(trusted_hosts) do
    with {:ok, host} <- host_from_url(url),
         {:ok, trusted_hosts} <- normalize_hosts(trusted_hosts),
         true <- Enum.member?(trusted_hosts, host) do
      {:ok, [host]}
    else
      false -> {:error, "Host is not trusted for outbound requests."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_trusted_hosts(_url, _trusted_hosts) do
    {:error, "Invalid trusted hosts configuration."}
  end

  defp host_from_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        case normalize_host(host) do
          {:ok, normalized_host} -> {:ok, normalized_host}
          :error -> {:error, "Could not parse outbound request host."}
        end

      _ ->
        {:error, "Could not parse outbound request host."}
    end
  rescue
    _error -> {:error, "Could not parse outbound request host."}
  end

  defp normalize_hosts(trusted_hosts) do
    Enum.reduce_while(trusted_hosts, {:ok, []}, fn trusted_host, {:ok, normalized_hosts} ->
      case normalize_host(trusted_host) do
        {:ok, normalized_host} ->
          {:cont, {:ok, [normalized_host | normalized_hosts]}}

        :error ->
          {:halt, {:error, "Invalid trusted hosts configuration."}}
      end
    end)
  end

  defp normalize_host(host) when is_binary(host) do
    case host |> String.trim() |> String.trim_trailing(".") |> String.downcase() do
      "" -> :error
      normalized_host -> {:ok, normalized_host}
    end
  end

  defp normalize_host(_host), do: :error

  defp validate_trusted_authorities(trusted_authorities) do
    case String.trim(trusted_authorities) do
      "" ->
        {:ok, []}

      authorities ->
        decode_trusted_authorities(authorities)
    end
  end

  defp decode_trusted_authorities(authorities) do
    authorities
    |> :public_key.pem_decode()
    |> Enum.filter(&match?({:Certificate, _, :not_encrypted}, &1))
    |> Enum.map(fn {:Certificate, der, :not_encrypted} -> der end)
    |> case do
      [] -> {:error, "Trusted authorities must contain PEM certificates."}
      cacerts -> {:ok, cacerts}
    end
  end

  defp trusted_get(url, trusted_hosts, trusted_authorities) do
    with {:ok, url, cacerts} <- get_cacerts(url, trusted_hosts, trusted_authorities),
         {:ok, :https} <- url_scheme(url) do
      fetch(url, cacerts)
    else
      {:ok, :http} -> {:error, "Certificate pinning requires HTTPS."}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch(url, cacerts) do
    options =
      put_adapter(
        [
          method: "GET",
          headers: [{"connection", "close"}],
          redirect: :manual,
          timeout: @receive_timeout,
          ssl: [cacerts: cacerts]
        ],
        Config.http_adapter()
      )

    url
    |> HTTP.fetch(options)
    |> HTTP.Promise.await(@receive_timeout + 5_000)
    |> to_response()
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  defp put_adapter(options, nil), do: options
  defp put_adapter(options, adapter), do: Keyword.put(options, :adapter, adapter)

  defp to_response(%HTTP.Response{} = response) do
    {:ok,
     %{
       status: response.status,
       headers: HTTP.Headers.to_list(response.headers),
       body: HTTP.Response.read_all(response)
     }}
  rescue
    error in HTTP.ResponseError -> {:error, error.reason}
  end

  defp to_response({:error, {:tls_alert, _alert}}),
    do: {:error, "Host certificate is not trusted."}

  defp to_response({:error, reason}), do: {:error, reason}

  defp url_scheme(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "" <> _host} -> {:ok, :https}
      %URI{scheme: "http", host: "" <> _host} -> {:ok, :http}
      _uri -> {:error, "Could not parse outbound request host."}
    end
  end

  def get_cacerts(url, trusted_hosts, trusted_authorities) when trusted_hosts != [] do
    with {:ok, host} <- host_from_url(url),
         true <- Enum.member?(trusted_hosts, host) do
      case trusted_authorities do
        [] ->
          {:ok, url, :public_key.cacerts_get()}

        trusted_authorities ->
          {:ok, url, trusted_authorities}
      end
    else
      false -> {:error, "Request URL host is not trusted."}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_cacerts(url, _trusted_hosts, trusted_authorities) do
    {:ok, url, trusted_authorities}
  end
end
