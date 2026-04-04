defmodule Relayixir.Proxy.HeadersTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.Headers
  alias Relayixir.Proxy.Upstream

  describe "prepare_request_headers/3" do
    test "strips hop-by-hop headers" do
      conn =
        Plug.Test.conn(:get, "http://example.com/test")
        |> Map.put(:req_headers, [
          {"host", "example.com"},
          {"connection", "keep-alive"},
          {"keep-alive", "timeout=5"},
          {"transfer-encoding", "chunked"},
          {"upgrade", "websocket"},
          {"proxy-authenticate", "Basic"},
          {"proxy-authorization", "Bearer xyz"},
          {"te", "trailers"},
          {"trailers", "Max-Forwards"},
          {"accept", "text/html"},
          {"x-custom", "value"}
        ])

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 80,
        host_forward_mode: :preserve
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      header_names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)

      refute "connection" in header_names
      refute "keep-alive" in header_names
      refute "transfer-encoding" in header_names
      refute "upgrade" in header_names
      refute "proxy-authenticate" in header_names
      refute "proxy-authorization" in header_names
      refute "te" in header_names
      refute "trailers" in header_names

      assert "accept" in header_names
      assert "x-custom" in header_names
    end

    test "strips Expect: 100-continue" do
      conn =
        Plug.Test.conn(:post, "http://example.com/upload")
        |> Map.put(:req_headers, [
          {"host", "example.com"},
          {"expect", "100-continue"},
          {"content-type", "application/octet-stream"}
        ])

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 80,
        host_forward_mode: :preserve
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      header_names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)

      refute "expect" in header_names
      assert "content-type" in header_names
    end

    test "sets x-forwarded-for, x-forwarded-proto, x-forwarded-host" do
      conn =
        Plug.Test.conn(:get, "http://example.com/test")
        |> Map.put(:remote_ip, {10, 0, 0, 1})

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 80,
        host_forward_mode: :preserve
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      headers_map = Map.new(headers)

      assert headers_map["x-forwarded-for"] == "10.0.0.1"
      assert headers_map["x-forwarded-proto"] == "http"
      assert headers_map["x-forwarded-host"] == "example.com"
    end

    test "appends to existing x-forwarded-for" do
      conn =
        Plug.Test.conn(:get, "http://example.com/test")
        |> Map.put(:remote_ip, {192, 168, 1, 1})
        |> Map.put(:req_headers, [
          {"host", "example.com"},
          {"x-forwarded-for", "10.0.0.1"}
        ])

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 80,
        host_forward_mode: :preserve
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      xff = Enum.find_value(headers, fn {k, v} -> if k == "x-forwarded-for", do: v end)

      assert xff == "10.0.0.1, 192.168.1.1"
    end

    test "host forwarding mode :preserve keeps original host" do
      conn = Plug.Test.conn(:get, "http://myapp.com/test")

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 8080,
        host_forward_mode: :preserve
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

      assert host == "myapp.com"
    end

    test "host forwarding mode :rewrite_to_upstream sets upstream host" do
      conn = Plug.Test.conn(:get, "http://myapp.com/test")

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 8080,
        host_forward_mode: :rewrite_to_upstream
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

      assert host == "backend.local:8080"
    end

    test "host forwarding mode :rewrite_to_upstream omits default port 80 for http" do
      conn = Plug.Test.conn(:get, "http://myapp.com/test")

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 80,
        host_forward_mode: :rewrite_to_upstream
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

      assert host == "backend.local"
    end

    test "host forwarding mode :rewrite_to_upstream omits default port 443 for https" do
      conn = Plug.Test.conn(:get, "https://myapp.com/test")

      upstream = %Upstream{
        scheme: :https,
        host: "backend.local",
        port: 443,
        host_forward_mode: :rewrite_to_upstream
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

      assert host == "backend.local"
    end

    test "host forwarding mode :route_defined uses metadata host" do
      conn = Plug.Test.conn(:get, "http://myapp.com/test")

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 8080,
        host_forward_mode: :route_defined,
        metadata: %{host: "custom.host.com"}
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

      assert host == "custom.host.com"
    end

    test "host forwarding mode :route_defined falls back to upstream host when no metadata" do
      conn = Plug.Test.conn(:get, "http://myapp.com/test")

      upstream = %Upstream{
        scheme: :http,
        host: "backend.local",
        port: 9090,
        host_forward_mode: :route_defined,
        metadata: %{}
      }

      headers = Headers.prepare_request_headers(conn, upstream)
      host = Enum.find_value(headers, fn {k, v} -> if k == "host", do: v end)

      assert host == "backend.local:9090"
    end
  end

  describe "prepare_response_headers/1" do
    test "strips hop-by-hop headers from response" do
      headers = [
        {"content-type", "text/html"},
        {"connection", "keep-alive"},
        {"transfer-encoding", "chunked"},
        {"x-custom", "value"},
        {"keep-alive", "timeout=5"}
      ]

      result = Headers.prepare_response_headers(headers)
      result_names = Enum.map(result, fn {name, _} -> name end)

      assert "content-type" in result_names
      assert "x-custom" in result_names
      refute "connection" in result_names
      refute "transfer-encoding" in result_names
      refute "keep-alive" in result_names
    end

    test "returns empty list for empty input" do
      assert Headers.prepare_response_headers([]) == []
    end
  end

  describe "format_ip/1" do
    test "formats IPv4 address" do
      assert Headers.format_ip({127, 0, 0, 1}) == "127.0.0.1"
      assert Headers.format_ip({192, 168, 1, 100}) == "192.168.1.100"
      assert Headers.format_ip({0, 0, 0, 0}) == "0.0.0.0"
    end

    test "formats IPv6 address" do
      result = Headers.format_ip({0, 0, 0, 0, 0, 0, 0, 1})
      assert result == "0:0:0:0:0:0:0:1"
    end

    test "formats IPv6 address with hex values" do
      result = Headers.format_ip({8193, 3512, 0, 0, 0, 0, 0, 1})
      # 8193 = 0x2001, 3512 = 0xDB8
      assert result == "2001:db8:0:0:0:0:0:1"
    end

    test "passes through string IP" do
      assert Headers.format_ip("10.0.0.1") == "10.0.0.1"
    end
  end
end
