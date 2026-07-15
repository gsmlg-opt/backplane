defmodule Backplane.Api.EndpointTest do
  use ExUnit.Case, async: true

  test "disables origin checks" do
    endpoint_config = Application.fetch_env!(:backplane_api, Backplane.Api.Endpoint)

    assert Keyword.fetch!(endpoint_config, :check_origin) == false
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
