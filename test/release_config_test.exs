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

  test "root asset deploy runs the isolated web asset orchestrator" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert is_function(aliases[:"assets.deploy"], 1)
  end

  test "build and release workflows verify assets inside packaged releases" do
    for path <- [".github/workflows/build.yml", ".github/workflows/release.yml"] do
      workflow = File.read!(path)

      assert workflow =~ "run: mix assets.deploy"

      assert workflow =~
               "elixir -pa _build/prod/lib/jason/ebin scripts/verify_web_assets.exs --release _build/prod/rel/backplane"

      assert workflow =~ "elixir test/build_web_assets_script_test.exs"

      refute workflow =~ ~s(mix "do" --app backplane_api assets.deploy)
      refute workflow =~ ~s(mix "do" --app backplane_admin assets.deploy)
    end

    release_workflow = File.read!(".github/workflows/release.yml")
    assert release_workflow =~ "python3 scripts/verify_web_assets_http.py"
    assert release_workflow =~ "installed/backplane/bin/backplane daemon"
    assert release_workflow =~ "http://127.0.0.1:14100/docs"
    assert release_workflow =~ "http://127.0.0.1:14101/dashboard/overview"
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

    assert release_workflow =~ "hex-packages:"

    for package <- [
          "backplane_agent_runtime",
          "backplane_ai_protocol",
          "backplane_skill_protocol",
          "backplane_mcp_protocol"
        ] do
      assert release_workflow =~ "name: #{package}"
      assert release_workflow =~ "Publish ${{ matrix.package.name }} to Hex"
    end

    assert release_workflow =~ "Install package publishing dependencies"
    assert release_workflow =~ "Verify package documentation"
    assert release_workflow =~ "mix docs"
    assert release_workflow =~ "mix hex.publish --yes"
    assert release_workflow =~ ~r/docker-image:.*needs:.*hex-packages/s
  end

  test "published agent runtime provides a documentation task without production dependencies" do
    package_mix = File.read!("apps/backplane_agent_runtime/mix.exs")

    assert package_mix =~ "{:ex_doc, \">= 0.0.0\", only: :dev, runtime: false}"
    assert package_mix =~ "main: \"readme\""

    for guide <- ~w(README.md EMBEDDING.md PERSISTENCE.md SCHEMAS.md CHANGELOG.md) do
      assert package_mix =~ guide
    end
  end

  test "Hex protocol packages can generate documentation from their app directories" do
    for path <- [
          "apps/backplane_ai_protocol/mix.exs",
          "apps/backplane_skill_protocol/mix.exs"
        ] do
      package_mix = File.read!(path)

      assert package_mix =~ "{:ex_doc, \">= 0.0.0\", only: :dev, runtime: false}"
      assert package_mix =~ "build_path: \"../../_build\""
      assert package_mix =~ "config_path: \"../../config/config.exs\""
      assert package_mix =~ "deps_path: \"../../deps\""
      assert package_mix =~ "lockfile: \"../../mix.lock\""
    end
  end

  test "release gates publication on Memory V2 qualification and installed migration smoke" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ "mix run --no-start test/release_config_test.exs"
    assert workflow =~ "qualify-memory-v2:"
    assert workflow =~ "m18_migration_chain_test.exs"
    assert workflow =~ "memory_v2_upgrade_test.exs"
    assert workflow =~ "v1_to_v2_upgrade_test.exs"
    assert workflow =~ "coalesce_projection_repairs_migration_test.exs"
    assert workflow =~ "projection_repair_worker_test.exs"
    assert workflow =~ "--exclude memory_qualification_runtime"
    assert workflow =~ "memory_m18_outage_qualification_test.exs"
    assert workflow =~ "memory_v2_edge_qualification_test.exs"
    assert workflow =~ "mix backplane.memory.edge_cutover_check"
    assert workflow =~ "Resolve migration-seeded empty memory slots in the qualification database"
    assert workflow =~ "bpm_memory_backfill_source_id('memory_slots', to_jsonb(slot))"
    assert workflow =~ "size_limit_chars <> 2000"
    assert workflow =~ "host_id IS NOT NULL OR client_id IS NOT NULL"
    assert workflow =~ "source_client_id IS NOT NULL OR memory_space_id IS NOT NULL"

    {migration_offset, _} = :binary.match(workflow, "mix ecto.migrate")

    {seed_resolution_offset, _} =
      :binary.match(workflow, "- name: Resolve migration-seeded empty memory slots")

    {cutover_offset, _} =
      :binary.match(workflow, "- name: Verify revisioned edge cutover readiness")

    assert migration_offset < seed_resolution_offset and seed_resolution_offset < cutover_offset
    refute workflow =~ "capture_performance_test.exs"
    assert workflow =~ "BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=true mix memory.qualify"
    assert workflow =~ ~r/mix memory\.qualify \\\s+--profile ci/
    assert workflow =~ "memory-v2-m18-ci-smoke.json"
    assert workflow =~ "mix memory.replay.browser_qualify"
    assert workflow =~ "memory-v2-replay-browser.json"
    assert workflow =~ "mix memory.eval"
    assert workflow =~ ~r/mix memory\.eval \\\s+--profile ci/
    assert workflow =~ "memory-v2-eval-ci-smoke.json"

    {seed_offset, _} = :binary.match(workflow, "mix memory.seed_bench")

    {real_pool_offset, _} =
      :binary.match(workflow, "BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL=true mix memory.qualify")

    assert seed_offset < real_pool_offset

    [qualification_job, _rest] = String.split(workflow, "  build:", parts: 2)
    refute qualification_job =~ "_build/test"
    assert qualification_job =~ "release-memory-v2-qualification-v2-"

    assert Backplane.Repo.config()[:pool_size] >= 10

    assert workflow =~ "postgresql-17"
    assert workflow =~ "CREATE EXTENSION IF NOT EXISTS vector"
    assert workflow =~ "installed-release-migration-smoke:"
    assert workflow =~ "installed/backplane/bin/backplane eval"
    assert workflow =~ "second installed migration pass was not a no-op"
    assert workflow =~ "Checkout authoritative migration inventory"
    assert workflow =~ "EXPECTED_LATEST_MIGRATION"
    assert workflow =~ "Installed release is missing authoritative migration"
    assert workflow =~ "last_version == expected_latest_migration"
    refute workflow =~ ~r/last_version == \d{14}/

    for table <- ~w(bpm_events memory_import_batches bpm_memory_spaces bpm_memory_changes) do
      assert workflow =~ table
    end

    assert workflow =~
             ~r/publish:.*needs:\s+- qualify-memory-v2\s+- build\s+- installed-release-migration-smoke/s

    for path <- [
          "docs/operations/memory-v2.md",
          "docs/deploy/memory-v2-release.md",
          "docs/qualification/memory-v2.md",
          "docs/memory/host-memory-v2-protocol.md",
          "docs/operations/host-memory-edge-runbook.md"
        ] do
      assert File.regular?(path), "missing release runbook #{path}"
      assert workflow =~ path
    end
  end

  test "GitHub test workflow excludes the authoritative local performance suite" do
    workflow = File.read!(".github/workflows/test.yml")

    assert workflow =~
             "mix do --app backplane_memory cmd mix test --exclude memory_qualification_runtime"
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
