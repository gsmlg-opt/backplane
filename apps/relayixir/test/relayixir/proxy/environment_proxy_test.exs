defmodule Relayixir.Proxy.EnvironmentProxyTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.EnvironmentProxy

  test "WSS uses HTTPS proxy policy and keeps proxy authorization in tunnel options" do
    env = %{
      "HTTPS_PROXY" => "http://user:pass@proxy.internal:3128",
      "HTTP_PROXY" => "http://fallback.internal:8080"
    }

    assert EnvironmentProxy.websocket_options("wss://api.openai.com/v1/responses", 5000, env) ==
             [
               proxy:
                 {:http, "proxy.internal", 3128,
                  [
                    headers: [{"proxy-authorization", "Basic " <> Base.encode64("user:pass")}],
                    timeout: 5000
                  ]}
             ]

    assert EnvironmentProxy.websocket_options("ws://api.example/socket", 5000, env) ==
             [proxy: {:http, "fallback.internal", 8080, [headers: [], timeout: 5000]}]
  end

  test "WebSocket NO_PROXY selects direct transport" do
    env = %{"HTTPS_PROXY" => "http://proxy.internal:3128", "NO_PROXY" => ".openai.com"}

    assert EnvironmentProxy.websocket_options("wss://api.openai.com/v1/responses", 5000, env) ==
             []

    assert EnvironmentProxy.websocket_options("ws://localhost/socket", 5000, %{}) == []
  end

  test "uses the HTTPS proxy for an HTTPS target" do
    env = %{
      "HTTPS_PROXY" => "http://proxy.internal:3128",
      "HTTP_PROXY" => "http://fallback.internal:8080"
    }

    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, env) ==
             [proxy: {:http, "proxy.internal", 3128, []}]
  end

  test "falls back to HTTP_PROXY and ALL_PROXY" do
    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, %{
             "HTTP_PROXY" => "http://http-proxy.internal:8080"
           }) == [proxy: {:http, "http-proxy.internal", 8080, []}]

    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, %{
             "ALL_PROXY" => "http://all-proxy.internal:8888"
           }) == [proxy: {:http, "all-proxy.internal", 8888, []}]
  end

  test "supports lowercase environment variables" do
    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, %{
             "https_proxy" => "http://proxy.internal:3128"
           }) == [proxy: {:http, "proxy.internal", 3128, []}]
  end

  test "bypasses exact and subdomain NO_PROXY entries" do
    env = %{
      "HTTPS_PROXY" => "http://proxy.internal:3128",
      "NO_PROXY" => "localhost,127.0.0.1,.internal.example"
    }

    assert EnvironmentProxy.connect_options(:https, "127.0.0.1", 443, env) == []
    assert EnvironmentProxy.connect_options(:https, "api.internal.example", 443, env) == []

    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, env) ==
             [proxy: {:http, "proxy.internal", 3128, []}]
  end

  test "adds basic proxy authorization without exposing credentials in the proxy tuple" do
    env = %{"HTTPS_PROXY" => "http://proxy-user:proxy-pass@proxy.internal:3128"}

    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, env) == [
             proxy: {:http, "proxy.internal", 3128, []},
             proxy_headers: [
               {"proxy-authorization", "Basic " <> Base.encode64("proxy-user:proxy-pass")}
             ]
           ]
  end

  test "ignores blank, malformed, and unsupported proxy URLs" do
    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, %{
             "HTTPS_PROXY" => " "
           }) == []

    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, %{
             "HTTPS_PROXY" => "socks5://proxy.internal:1080"
           }) == []

    assert EnvironmentProxy.connect_options(:https, "chatgpt.com", 443, %{
             "HTTPS_PROXY" => "not-a-url"
           }) == []
  end
end
