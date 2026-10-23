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
    # credo:disable-for-next-line Credo.Check.Design.TagTODO
    # TODO(upstream): gsmlg-opt/backplane#77
    with :ok <- check_origin(request, Keyword.get(opts, :allowed_origin)),
         {:ok, resp} <-
           Finch.request(request, Backplane.McpProtocol.Finch, Keyword.delete(opts, :allowed_origin)),
         do: do_follow_redirect(request, resp, opts, attempts)
  end

  @doc "Checks an optional origin boundary before sending configured HTTP headers."
  def check_origin(_url, nil), do: :ok

  def check_origin(%Finch.Request{} = request, allowed) do
    check_origin(%URI{scheme: to_string(request.scheme), host: request.host, port: request.port}, allowed)
  end

  def check_origin(url, allowed) do
    with {:ok, uri} <- URI.new(url),
         {:ok, origin} <- URI.new(allowed),
         true <- uri.scheme in ["http", "https"] and not is_nil(uri.host),
         true <- is_nil(uri.userinfo),
         true <-
           {String.downcase(uri.scheme), String.downcase(uri.host), uri.port} ==
             {String.downcase(origin.scheme || ""), String.downcase(origin.host || ""), origin.port} do
      :ok
    else
      _ -> {:error, :cross_origin_redirect}
    end
  end

  defp do_follow_redirect(_req, %Finch.Response{status: 307}, _opts, 0), do: {:error, :max_redirects}

  defp do_follow_redirect(req, %Finch.Response{status: 307, headers: headers}, opts, attempts)
       when is_integer(attempts) do
    location = Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == "location", do: value end)

    Backplane.McpProtocol.Logging.transport_event("redirect", %{
      location: location,
      attempts_left: attempts,
      method: req.method
    })

    with true <- is_binary(location),
         {:ok, uri} <- URI.new(location),
         base = %URI{scheme: to_string(req.scheme), host: req.host, port: req.port, path: req.path, query: req.query},
         uri = URI.merge(base, uri),
         true <- uri.scheme in ["http", "https"] and not is_nil(uri.host),
         :ok <- check_origin(uri, Keyword.get(opts, :allowed_origin)) do
      redirected = Finch.build(req.method, URI.to_string(uri), req.headers, req.body)
      follow_redirect(redirected, opts, attempts - 1)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_redirect}
    end
  end

  defp do_follow_redirect(_req, %Finch.Response{} = resp, _opts, _attempts), do: {:ok, resp}
end
