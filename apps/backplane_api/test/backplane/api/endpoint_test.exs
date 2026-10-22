defmodule Backplane.Api.EndpointTest do
  use ExUnit.Case, async: true

  test "disables origin checks" do
    endpoint_config = Application.fetch_env!(:backplane_api, Backplane.Api.Endpoint)

    assert Keyword.fetch!(endpoint_config, :check_origin) == false
  end

  test "bounds host-agent WebSocket frames above the logical memory event payload limit" do
    assert {"/host-agent/socket", Backplane.Api.HostAgentSocket, socket_options} =
             Enum.find(Backplane.Api.Endpoint.__sockets__(), fn {path, _socket, _options} ->
               path == "/host-agent/socket"
             end)

    websocket_options = Keyword.fetch!(socket_options, :websocket)
    assert Keyword.fetch!(websocket_options, :max_frame_size) == 640 * 1024
  end

  test "retains finite request, upload and HTTP/2 limits at the Gaoxy adapter" do
    endpoint_config = Application.fetch_env!(:backplane_api, Backplane.Api.Endpoint)
    assert Keyword.fetch!(endpoint_config, :adapter) == Gaoxy.PhoenixAdapter
    http = Keyword.fetch!(endpoint_config, :http)
    assert Keyword.fetch!(http, :http_limits).request_timeout == 600_000
    assert Keyword.fetch!(http, :http_limits).max_buffer_bytes == 65_537
    assert Keyword.fetch!(http, :http_limits).max_body_bytes >= 25_000_000 + 65_536
    assert Keyword.fetch!(http, :limits).max_bytes >= 4 * 640 * 1024
    assert Keyword.fetch!(http, :protocols) == [:http2, :http1]
    assert Keyword.fetch!(http, :h2c) == :prior_knowledge
  end

  test "dev code reloader does not reload the standalone host agent app" do
    reloadable_apps =
      Path.expand("../../../../../config/dev.exs", __DIR__)
      |> Config.Reader.read!(env: :dev)
      |> Keyword.fetch!(:backplane_api)
      |> Keyword.fetch!(Backplane.Api.Endpoint)
      |> Keyword.fetch!(:reloadable_apps)

    assert :backplane_api in reloadable_apps
    assert :backplane in reloadable_apps
    refute :backplane_host_agent in reloadable_apps
  end
end
