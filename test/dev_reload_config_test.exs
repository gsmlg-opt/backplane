ExUnit.start()

defmodule Backplane.DevReloadConfigTest do
  use ExUnit.Case, async: true

  test "reloads the AI protocol app from both development endpoints" do
    config =
      Path.expand("../config/dev.exs", __DIR__)
      |> Config.Reader.read!(env: :dev)

    api_reloadable_apps =
      config
      |> Keyword.fetch!(:backplane_api)
      |> Keyword.fetch!(Backplane.Api.Endpoint)
      |> Keyword.fetch!(:reloadable_apps)

    admin_reloadable_apps =
      config
      |> Keyword.fetch!(:backplane_admin)
      |> Keyword.fetch!(Backplane.Admin.Endpoint)
      |> Keyword.fetch!(:reloadable_apps)

    assert :backplane_ai_protocol in api_reloadable_apps
    assert :backplane_ai_protocol in admin_reloadable_apps
    assert api_reloadable_apps == admin_reloadable_apps
  end
end
