defmodule Backplane.HostAgent.VersionTest do
  use ExUnit.Case, async: true

  test "reports the development suffix without changing the application version" do
    application_version = Application.spec(:backplane_host_agent, :vsn) |> to_string()
    suffix = if Mix.env() == :dev, do: "-dev", else: ""

    assert Backplane.HostAgent.version() == application_version <> suffix
    assert application_version == Mix.Project.config()[:version]
  end
end
