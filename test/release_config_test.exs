defmodule Backplane.ReleaseConfigTest do
  use ExUnit.Case, async: true

  test "umbrella defines backplane and host agent releases" do
    releases = Mix.Project.config() |> Keyword.fetch!(:releases)

    assert [:backplane, :host_agent] = Keyword.keys(releases)

    assert releases[:backplane][:applications][:backplane] == :permanent
    assert releases[:backplane][:applications][:backplane_api] == :permanent
    assert releases[:backplane][:applications][:backplane_admin] == :permanent
    assert releases[:backplane][:applications][:backplane_memory] == :permanent
    refute Keyword.has_key?(releases[:backplane][:applications], :backplane_host_agent)

    assert releases[:host_agent][:applications][:backplane_host_agent] == :permanent
    assert releases[:host_agent][:runtime_config_path] == "config/host_agent_runtime.exs"
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane)
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane_api)
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane_admin)
  end

  test "host agent runtime config does not require Phoenix secrets" do
    runtime_config_path =
      Mix.Project.config()
      |> Keyword.fetch!(:releases)
      |> get_in([:host_agent, :runtime_config_path])

    runtime_config = File.read!(runtime_config_path)

    refute runtime_config =~ "SECRET_KEY_BASE"
    refute runtime_config =~ "BackplaneWeb.Endpoint"
  end

  test "root mix release is an alias for building both configured releases" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert is_function(aliases[:release], 1)
  end

  test "host agent copies integrations with a post-assembly release step" do
    host_agent =
      Mix.Project.config()
      |> Keyword.fetch!(:releases)
      |> Keyword.fetch!(:host_agent)

    refute Keyword.has_key?(host_agent, :overlays)
    assert [:assemble, copy_integrations] = host_agent[:steps]
    assert is_function(copy_integrations, 1)
  end

  test "published backplane_mcp_protocol install examples use the package version" do
    package_mix = File.read!("apps/backplane_mcp_protocol/mix.exs")
    [_, version] = Regex.run(~r/@version "([^"]+)"/, package_mix)
    dependency = ~s({:backplane_mcp_protocol, "~> #{version}"})

    for path <- [
          "apps/backplane_mcp_protocol/README.md",
          "apps/backplane_mcp_protocol/pages/introduction.md",
          "apps/backplane_mcp_protocol/pages/building-a-server.md"
        ] do
      contents = File.read!(path)

      assert contents =~ dependency,
             "#{path} must recommend the active Hex package version #{version}"
    end
  end

  test "umbrella releases do not version or publish the Hex package" do
    version_script = File.read!("scripts/set-version.sh")
    release_workflow = File.read!(".github/workflows/release.yml")

    assert version_script =~
             ~r/if \[\[ "\$file" == "apps\/backplane_mcp_protocol\/mix\.exs" \]\]; then\s+continue/

    refute release_workflow =~ "Publish backplane_mcp_protocol to Hex"
    refute release_workflow =~ "mix hex.publish"
  end
end
