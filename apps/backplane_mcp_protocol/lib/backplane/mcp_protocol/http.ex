defmodule Backplane.McpProtocol.HTTP do
  @moduledoc false

  use Backplane.McpProtocol.Logging

  @default_headers %{
    "content-type" => "application/json"
  }

  def build(method, url, headers \\ %{}, body \\ nil) do
    with {:ok, uri} <- parse_uri(url) do
      headers = Map.merge(@default_headers, headers)
      Finch.build(method, uri, Map.to_list(headers), body)
    end
  end

  @doc """
  Performs a POST request to the given URL.
  """
  def post(url, headers \\ %{}, body \\ nil) do
    headers = Map.merge(@default_headers, headers)
    build(:post, url, headers, body)
  end

  defp parse_uri(url) do
    with {:error, _} <- URI.new(url), do: {:error, :invalid_url}
  end

  @max_redirects 3

  @spec follow_redirect(Finch.Request.t(), keyword(), non_neg_integer()) ::
          {:ok, Finch.Response.t()} | {:error, term()}
  def follow_redirect(%Finch.Request{} = request, opts \\ [], attempts \\ @max_redirects) do
    with :ok <- check_origin(request, Keyword.get(opts, :allowed_origin)),
         {:ok, resp} <-
           Finch.request(
             request,
             Backplane.McpProtocol.Finch,
             Keyword.delete(opts, :allowed_origin)
           ),
         do: do_follow_redirect(request, resp, opts, attempts)
  end

  @doc "Checks an optional HTTP origin boundary before configured headers are sent."
  @spec check_origin(Finch.Request.t() | URI.t() | String.t(), URI.t() | String.t() | nil) ::
          :ok | {:error, :cross_origin_redirect}
  def check_origin(_url, nil), do: :ok

  def check_origin(%Finch.Request{} = request, allowed) do
    check_origin(request_uri(request), allowed)
  end

  def check_origin(url, allowed) do
    with {:ok, origin} <- origin(url),
         {:ok, ^origin} <- origin(allowed) do
      :ok
    else
      _invalid_or_foreign -> {:error, :cross_origin_redirect}
    end
  end

  defp origin(url) when is_binary(url) or is_struct(url, URI) do
    with {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil}} <- URI.new(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, {scheme, String.downcase(host), port}}
    else
      _invalid -> :error
    end
  end

  defp origin(_invalid), do: :error

  defp do_follow_redirect(_req, %Finch.Response{status: 307}, _opts, 0),
    do: {:error, :max_redirects}

  defp do_follow_redirect(req, %Finch.Response{status: 307, headers: headers}, opts, attempts)
       when is_integer(attempts) do
    location =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(key) == "location", do: value
      end)

    Backplane.McpProtocol.Logging.transport_event("redirect", %{
      location: location,
      attempts_left: attempts,
      method: req.method
    })

    with {:ok, uri} <- redirect_uri(req, location),
         :ok <- check_origin(uri, Keyword.get(opts, :allowed_origin)) do
      redirected = Finch.build(req.method, uri, req.headers, req.body)

      request = %{
        req
        | scheme: redirected.scheme,
          host: redirected.host,
          port: redirected.port,
          path: redirected.path,
          query: redirected.query
      }

      follow_redirect(request, opts, attempts - 1)
    end
  end

  defp do_follow_redirect(_req, %Finch.Response{} = resp, _opts, _attempts), do: {:ok, resp}

  defp redirect_uri(req, location) when is_binary(location) and location != "" do
    base = request_uri(req)

    with {:ok, uri} <- URI.new(location),
         uri = URI.merge(base, uri),
         {:ok, _origin} <- origin(uri) do
      {:ok, uri}
    else
      _invalid -> {:error, :invalid_redirect}
    end
  end

  defp redirect_uri(_req, _location), do: {:error, :invalid_redirect}

  defp request_uri(request) do
    host =
      if String.contains?(request.host, ":"),
        do: "[#{request.host}]",
        else: request.host

    uri = URI.parse("#{request.scheme}://#{host}:#{request.port}")
    %{uri | path: request.path, query: request.query}
  end
end
