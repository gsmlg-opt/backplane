defmodule Backplane.Admin.EndpointTest do
  use ExUnit.Case, async: false

  @admin_env_vars ~w(BACKPLANE_ADMIN_USERNAME BACKPLANE_ADMIN_PASSWORD)

  setup do
    previous_env = Map.new(@admin_env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

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

  test "dev admin endpoint accepts remote connections and reads credentials from env" do
    System.put_env("BACKPLANE_ADMIN_USERNAME", "dev-admin")
    System.put_env("BACKPLANE_ADMIN_PASSWORD", "dev-secret")

    config =
      Path.expand("../../../../../config/dev.exs", __DIR__)
      |> Config.Reader.read!(env: :dev)

    endpoint_config =
      config
      |> Keyword.fetch!(:backplane_admin)
      |> Keyword.fetch!(Backplane.Admin.Endpoint)

    backplane_config = Keyword.fetch!(config, :backplane)

    assert endpoint_config[:http][:ip] == {0, 0, 0, 0}
    assert endpoint_config[:http][:port] == 4221
    assert backplane_config[:admin_username] == "dev-admin"
    assert backplane_config[:admin_password] == "dev-secret"
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
