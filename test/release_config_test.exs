ExUnit.start()

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

  test "umbrella releases version and publish the Hex package" do
    version_script = File.read!("scripts/set-version.sh")
    release_workflow = File.read!(".github/workflows/release.yml")

    refute version_script =~
             ~r/if \[\[ "\$file" == "apps\/backplane_mcp_protocol\/mix\.exs" \]\]; then\s+continue/

    assert release_workflow =~ "Publish backplane_mcp_protocol to Hex"
    assert release_workflow =~ "mix hex.publish --yes"
    assert release_workflow =~ ~r/docker-image:.*needs:.*hex-package/s
  end

  test "release gates publication on Memory V2 qualification and installed migration smoke" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ "mix run --no-start test/release_config_test.exs"
    assert workflow =~ "qualify-memory-v2:"
    assert workflow =~ "m18_migration_chain_test.exs"
    assert workflow =~ "memory_m18_outage_qualification_test.exs"
    assert workflow =~ "mix memory.qualify"
    assert workflow =~ "memory-v2-m18-qualification.json"
    assert workflow =~ "mix memory.replay.browser_qualify"
    assert workflow =~ "memory-v2-replay-browser.json"
    assert workflow =~ "mix memory.eval"
    assert workflow =~ "postgresql-17"
    assert workflow =~ "CREATE EXTENSION IF NOT EXISTS vector"
    assert workflow =~ "installed-release-migration-smoke:"
    assert workflow =~ "installed/backplane/bin/backplane eval"
    assert workflow =~ "second installed migration pass was not a no-op"
    assert workflow =~ "last_version == 20260812000022"

    assert workflow =~
             ~r/publish:.*needs:\s+- qualify-memory-v2\s+- build\s+- installed-release-migration-smoke/s

    for path <- [
          "docs/operations/memory-v2.md",
          "docs/deploy/memory-v2-release.md",
          "docs/qualification/memory-v2.md"
        ] do
      assert File.regular?(path), "missing release runbook #{path}"
      assert workflow =~ path
    end
  end

  test "release qualification pins one main-branch SHA and validates semver before builds" do
    workflow = File.read!(".github/workflows/release.yml")

    refute workflow =~ "inputs.git_ref"
    refute workflow =~ ~r/workflow_dispatch:\s+inputs:\s+git_ref:/
    refute workflow =~ ~s(version="${{ inputs.version }}")
    refute workflow =~ "steps.bump.outputs.commitish"
    refute workflow =~ "Commit version bump"

    assert workflow =~ "ref: refs/heads/main"
    assert workflow =~ "gated_sha: ${{ steps.gate.outputs.sha }}"
    assert workflow =~ "version: ${{ steps.gate.outputs.version }}"
    assert workflow =~ "RELEASE_VERSION_INPUT: ${{ inputs.version }}"
    assert workflow =~ "WORKFLOW_REF: ${{ github.ref }}"
    assert workflow =~ ~s([[ "$WORKFLOW_REF" != "refs/heads/main" ]])
    assert workflow =~ "GATED_SHA: ${{ needs.qualify-memory-v2.outputs.gated_sha }}"
    assert workflow =~ "ref: ${{ needs.qualify-memory-v2.outputs.gated_sha }}"
    assert workflow =~ "target_commitish: ${{ needs.qualify-memory-v2.outputs.gated_sha }}"
    assert workflow =~ ~s([[ "$sha" != "$main_sha" ]])
    assert workflow =~ "^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)"
  end

  test "deploy documentation preserves the separate trusted admin boundary" do
    deploy = File.read!("docs/deploy/backplane.md")
    proxy = File.read!("docs/deploy/caddy.md")

    assert deploy =~ "port `4101` is the separate admin UI"
    assert deploy =~ "There is no admin route on port"
    assert deploy =~ "trusted network"
    refute deploy =~ "4100/admin"

    assert proxy =~ "127.0.0.1:4101"
    assert proxy =~ "must resolve only on a trusted network"
  end
end
