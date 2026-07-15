defmodule Backplane.Admin.EndpointTest do
  use ExUnit.Case, async: true

  test "disables origin checks" do
    endpoint_config = Application.fetch_env!(:backplane_admin, Backplane.Admin.Endpoint)

    assert Keyword.fetch!(endpoint_config, :check_origin) == false
  end

  test "dev code reloader does not reload the standalone host agent app" do
    reloadable_apps =
      Path.expand("../../../../../config/dev.exs", __DIR__)
      |> Config.Reader.read!(env: :dev)
      |> Keyword.fetch!(:backplane_admin)
      |> Keyword.fetch!(Backplane.Admin.Endpoint)
      |> Keyword.fetch!(:reloadable_apps)

    assert :backplane_admin in reloadable_apps
    assert :backplane in reloadable_apps
    refute :backplane_host_agent in reloadable_apps
  end

  test "live socket only enables the websocket transport" do
    assert {"/live", Phoenix.LiveView.Socket, opts} =
             Enum.find(Backplane.Admin.Endpoint.__sockets__(), fn {path, _socket, _opts} ->
               path == "/live"
             end)

    assert Keyword.has_key?(opts, :websocket)
    assert Keyword.fetch!(opts, :longpoll) == false
  end

  test "admin LiveSocket does not enable longpoll fallback" do
    app_js = File.read!(Path.expand("../../../assets/js/app.js", __DIR__))

    refute app_js =~ "longPollFallbackMs"
  end
end
