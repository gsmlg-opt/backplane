defmodule Relayixir.Proxy.Headers do
  @moduledoc """
  Pure functions for HTTP header policy: hop-by-hop stripping, forwarding headers, host policy.
  """

  @hop_by_hop_headers %{
    "connection" => true,
    "keep-alive" => true,
    "proxy-authenticate" => true,
    "proxy-authorization" => true,
    "te" => true,
    "trailers" => true,
    "transfer-encoding" => true,
    "upgrade" => true
  }

  @doc """
  Prepares request headers for upstream forwarding.
  """
  @spec prepare_request_headers(Plug.Conn.t(), Relayixir.Proxy.Upstream.t(), keyword()) :: [
          {String.t(), String.t()}
        ]
  def prepare_request_headers(
        %Plug.Conn{} = conn,
        %Relayixir.Proxy.Upstream{} = upstream,
        opts \\ []
      ) do
    conn.req_headers
    |> strip_hop_by_hop()
    |> strip_expect_continue()
    |> set_host_header(conn, upstream)
    |> set_forwarding_headers(conn, opts)
  end

  @doc """
  Strips hop-by-hop headers from response headers.
  """
  @spec prepare_response_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def prepare_response_headers(headers) when is_list(headers) do
    strip_hop_by_hop(headers)
  end

  @doc """
  Formats an IP address tuple as a string.
  """
  @spec format_ip(tuple() | String.t()) :: String.t()
  def format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  def format_ip({a, b, c, d, e, f, g, h}),
    do:
      "#{int_to_hex(a)}:#{int_to_hex(b)}:#{int_to_hex(c)}:#{int_to_hex(d)}:#{int_to_hex(e)}:#{int_to_hex(f)}:#{int_to_hex(g)}:#{int_to_hex(h)}"

  def format_ip(ip) when is_binary(ip), do: ip

  defp int_to_hex(n), do: Integer.to_string(n, 16) |> String.downcase()

  defp strip_hop_by_hop(headers) do
    Enum.reject(headers, fn {name, _value} ->
      Map.has_key?(@hop_by_hop_headers, String.downcase(name))
    end)
  end

  defp strip_expect_continue(headers) do
    Enum.reject(headers, fn {name, value} ->
      String.downcase(name) == "expect" && String.downcase(value) =~ "100-continue"
    end)
  end

  defp set_host_header(headers, conn, upstream) do
    headers_without_host =
      Enum.reject(headers, fn {name, _} -> String.downcase(name) == "host" end)

    host_value =
      case upstream.host_forward_mode do
        :preserve ->
          conn.host

        :rewrite_to_upstream ->
          upstream_host_with_port(upstream)

        :route_defined ->
          host_from_metadata(upstream) || upstream_host_with_port(upstream)
      end

    [{"host", host_value} | headers_without_host]
  end

  defp upstream_host_with_port(%{host: host, port: 80, scheme: :http}), do: host
  defp upstream_host_with_port(%{host: host, port: 443, scheme: :https}), do: host
  defp upstream_host_with_port(%{host: host, port: port}), do: "#{host}:#{port}"

  defp host_from_metadata(%{metadata: %{host: host}}) when is_binary(host), do: host
  defp host_from_metadata(_), do: nil

  defp set_forwarding_headers(headers, conn, _opts) do
    client_ip = format_ip(conn.remote_ip)
    scheme = to_string(conn.scheme)
    host = conn.host

    headers
    |> put_or_append_header("x-forwarded-for", client_ip)
    |> put_header("x-forwarded-proto", scheme)
    |> put_header("x-forwarded-host", host)
  end

  defp put_header(headers, name, value) do
    [{name, value} | Enum.reject(headers, fn {n, _} -> n == name end)]
  end

  defp put_or_append_header(headers, name, value) do
    case List.keyfind(headers, name, 0) do
      {^name, existing} ->
        List.keyreplace(headers, name, 0, {name, "#{existing}, #{value}"})

      nil ->
        [{name, value} | headers]
    end
  end
end
