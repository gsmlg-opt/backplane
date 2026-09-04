defmodule Relayixir.Proxy.HttpClientTest do
  use ExUnit.Case, async: true

  alias Relayixir.Proxy.{HttpClient, Upstream}

  test "keeps upstreams direct by default" do
    upstream = %Upstream{scheme: :https, host: "chatgpt.com", port: 443}

    assert HttpClient.connect_options(upstream, %{
             "HTTPS_PROXY" => "http://proxy.internal:3128"
           }) == [protocols: [:http1], transport_opts: [timeout: 5_000]]
  end

  test "adds environment proxy options only when the upstream opts in" do
    upstream = %Upstream{
      scheme: :https,
      host: "chatgpt.com",
      port: 443,
      proxy: :environment,
      connect_timeout: 10_000
    }

    assert HttpClient.connect_options(upstream, %{
             "HTTPS_PROXY" => "http://proxy.internal:3128"
           }) == [
             protocols: [:http1],
             transport_opts: [timeout: 10_000],
             proxy:
               {:http, "proxy.internal", 3128,
                [transport_opts: [timeout: 10_000], tunnel_timeout: 10_000]}
           ]
  end

  test "retries environment proxy connection failures before a request is sent" do
    upstream = %Upstream{
      scheme: :https,
      host: "chatgpt.com",
      port: 443,
      proxy: :environment
    }

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    connector = fn _scheme, _host, _port, _options ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
      if attempt < 3, do: {:error, :proxy_timeout}, else: {:ok, :connected}
    end

    assert {:ok, :connected} =
             HttpClient.connect(upstream, connector, %{
               "HTTPS_PROXY" => "http://proxy.internal:3128"
             })

    assert Agent.get(attempts, & &1) == 3
  end

  test "does not retry direct connection failures" do
    upstream = %Upstream{scheme: :https, host: "chatgpt.com", port: 443}
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    connector = fn _scheme, _host, _port, _options ->
      Agent.update(attempts, &(&1 + 1))
      {:error, :timeout}
    end

    assert {:error, :timeout} = HttpClient.connect(upstream, connector, %{})
    assert Agent.get(attempts, & &1) == 1
  end
end
