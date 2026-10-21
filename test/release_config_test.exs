ExUnit.start()

defmodule Backplane.ReleaseConfigTest do
  use ExUnit.Case, async: true

  @runtime_release_apps ~w(backplane_admin backplane_api backplane_host_agent backplane_llama backplane_memory backplane_skills backplane_system)
  @mcp_examples ~w(apps/backplane_mcp_protocol/README.md apps/backplane_mcp_protocol/pages/introduction.md apps/backplane_mcp_protocol/pages/building-a-server.md)

  test "version script preserves unified versioning by default and with explicit all" do
    for selection <- [[], ["all"]] do
      directory = version_fixture()
      {_output, 0} = set_version(directory, ["v9.8.7" | selection])
      snapshot = version_snapshot(directory)

      for {path, contents} <- snapshot do
        if String.ends_with?(path, "mix.exs") do
          assert contents =~ ~r/(?:@version\s+|version:\s*)"9\.8\.7"/
        else
          assert contents =~ ~s({:backplane_mcp_protocol, "~> 9.8.7"})
        end
      end

      refute Enum.any?(Map.keys(snapshot), &String.ends_with?(&1, ".bak"))
    end
  end

  test "selected versioning preserves every unselected manifest and MCP example" do
    directory = version_fixture()
    before = version_snapshot(directory)
    {_output, 0} = set_version(directory, ["9.8.7" | @runtime_release_apps])
    after_snapshot = version_snapshot(directory)
    selected = ["mix.exs" | Enum.map(@runtime_release_apps, &"apps/#{&1}/mix.exs")]

    assert Map.keys(before) |> Enum.sort() == Map.keys(after_snapshot) |> Enum.sort()

    for {path, contents} <- before do
      if path in selected do
        assert after_snapshot[path] != contents
        assert after_snapshot[path] =~ ~r/(?:@version\s+|version:\s*)"9\.8\.7"/
      else
        assert after_snapshot[path] == contents, "unexpected change to #{path}"
      end
    end
  end

  test "selecting the MCP package updates only its manifest, examples and root" do
    directory = version_fixture()
    before = version_snapshot(directory)
    {_output, 0} = set_version(directory, ["9.8.7", "backplane_mcp_protocol"])
    after_snapshot = version_snapshot(directory)
    selected = ["mix.exs", "apps/backplane_mcp_protocol/mix.exs" | @mcp_examples]

    for {path, contents} <- before do
      assert after_snapshot[path] != contents == path in selected, path
    end
  end

  test "version script validates every selection before writing" do
    for arguments <- [
          ["invalid", "backplane_host_agent"],
          ["9.8.7", "backplane_host_agent", "unknown_app"],
          ["9.8.7", "backplane_host_agent", "../backplane_memory"],
          ["9.8.7", "all", "backplane_host_agent"],
          ["9.8.7", "backplane_host_agent", "all"],
          ["9.8.7", ""]
        ] do
      directory = version_fixture()
      before = version_snapshot(directory)
      {_output, status} = set_version(directory, arguments)

      assert status != 0, "accepted invalid arguments: #{inspect(arguments)}"
      assert version_snapshot(directory) == before
    end
  end

  test "version script validates all manifests and selected examples before writing" do
    for broken_path <- ["apps/backplane_system/mix.exs", List.last(@mcp_examples)] do
      directory = version_fixture()
      File.write!(Path.join(directory, broken_path), "no version field\n")
      before = version_snapshot(directory)
      {_output, status} = set_version(directory, ["9.8.7"])

      assert status != 0
      assert version_snapshot(directory) == before
    end
  end

  test "release defaults to full publication and explicitly gates selective runtime releases" do
    workflow = File.read!(".github/workflows/release.yml")

    assert workflow =~ ~r/release_apps:.*?type: string.*?default: all/s
    assert workflow =~ "RELEASE_APPS_INPUT: ${{ inputs.release_apps }}"
    assert workflow =~ "release_apps: ${{ steps.gate.outputs.release_apps }}"
    assert workflow =~ "release_apps: ${{ needs.qualify-memory-v2.outputs.release_apps }}"
    assert workflow =~ "Selective runtime releases must include backplane_host_agent"
    assert workflow =~ "Selective runtime releases cannot publish Hex packages"
    assert workflow =~ ~s(IFS=',' read -r -a release_apps <<< "$RELEASE_APPS")
    assert workflow =~ ~s(bash scripts/set-version.sh "$RELEASE_VERSION" "${release_apps[@]}")
    assert workflow =~ "if: needs.publish.outputs.release_apps == 'all'"

    assert workflow =~
             ~r/docker-image:.*?if: >-\s+\$\{\{ !cancelled\(\) &&\s+needs.publish.result == 'success' &&\s+\(needs.hex-packages.result == 'success' \|\|\s+\(needs.publish.outputs.release_apps != 'all' &&\s+needs.hex-packages.result == 'skipped'\)\) \}\}/s
  end

  test "release input gate accepts full or selected runtime apps and rejects invalid scope" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")

    gate =
      workflow["jobs"]["qualify-memory-v2"]["steps"]
      |> Enum.find(&(&1["id"] == "gate"))

    directory = version_fixture()
    binary_directory = Path.join(directory, "bin")
    File.mkdir_p!(binary_directory)
    git = Path.join(binary_directory, "git")
    File.write!(git, "#!/usr/bin/env bash\nprintf '%s\\n' fixture-sha\n")
    File.chmod!(git, 0o755)
    output_path = Path.join(directory, "gate-output")

    selections = ["all", Enum.join(@runtime_release_apps, ",")]

    invalid_selections = [
      "",
      "backplane_memory",
      "backplane_host_agent,unknown_app",
      "backplane_host_agent,../backplane_memory",
      "backplane_host_agent,",
      "backplane_host_agent,,backplane_memory",
      "all,backplane_host_agent"
    ]

    hex_selections =
      Enum.map(
        ~w(backplane_agent_runtime backplane_ai_protocol backplane_skill_protocol backplane_mcp_protocol),
        &"backplane_host_agent,#{&1}"
      )

    for selection <- selections ++ invalid_selections ++ hex_selections do
      File.write!(output_path, "")

      {output, status} =
        System.cmd("bash", ["-c", gate["run"]],
          cd: directory,
          stderr_to_stdout: true,
          env: [
            {"PATH", binary_directory <> ":" <> System.fetch_env!("PATH")},
            {"GITHUB_OUTPUT", output_path},
            {"WORKFLOW_REF", "refs/heads/main"},
            {"RELEASE_VERSION_INPUT", "9.8.7"},
            {"RELEASE_APPS_INPUT", selection}
          ]
        )

      if selection in selections do
        assert status == 0, output
        assert File.read!(output_path) =~ "release_apps=#{selection}\n"
      else
        assert status != 0, "accepted invalid release_apps: #{inspect(selection)}"
        assert File.read!(output_path) == ""
      end
    end
  end

  test "release refreshes compiled admin metadata and verifies it before archiving" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    steps = workflow["jobs"]["build"]["steps"]
    refresh = Enum.find(steps, &(&1["name"] == "Refresh compiled admin build metadata"))
    verify = Enum.find(steps, &(&1["name"] == "Verify compiled release metadata"))

    assert refresh["if"] == "matrix.release == 'backplane'"

    assert refresh["run"] ==
             ~s(mix "do" --app backplane_admin compile --force --warnings-as-errors)

    assert verify["if"] == "matrix.release == 'backplane'"
    assert verify["run"] =~ "_build/prod/rel/backplane/bin/backplane eval"

    ordered_steps = [
      "Build web assets",
      "Refresh compiled admin build metadata",
      "Build OTP release",
      "Verify compiled release metadata",
      "Archive OTP release"
    ]

    positions =
      Enum.map(ordered_steps, fn name -> Enum.find_index(steps, &(&1["name"] == name)) end)

    refute nil in positions
    assert positions == Enum.sort(positions)
  end

  test "compiled release metadata verification rejects stale builds despite runtime overrides" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")

    verify =
      workflow["jobs"]["build"]["steps"]
      |> Enum.find(&(&1["name"] == "Verify compiled release metadata"))

    directory = version_fixture()
    release_cli = Path.join(directory, "_build/prod/rel/backplane/bin/backplane")
    File.mkdir_p!(Path.dirname(release_cli))

    File.write!(release_cli, """
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$1" == eval ]]
    exec "$FIXTURE_ELIXIR" -r "$FIXTURE_BUILD_INFO" -e "$2"
    """)

    File.chmod!(release_cli, 0o755)
    build_info = Path.join(directory, "build_info.exs")

    metadata_env =
      ~w(BACKPLANE_GIT_REF BACKPLANE_GIT_SHA VCS_REF BACKPLANE_BUILD_DATE BACKPLANE_RELEASE_DATE)

    File.write!(build_info, """
    defmodule Backplane.Admin.BuildInfo do
      def current do
        for key <- #{inspect(metadata_env)} do
          if System.get_env(key), do: raise("runtime metadata override survived: " <> key)
        end

        %{
          git_sha: System.fetch_env!("FIXTURE_COMPILED_SHA"),
          version: System.fetch_env!("FIXTURE_COMPILED_VERSION"),
          environment: System.fetch_env!("FIXTURE_COMPILED_ENV")
        }
      end
    end
    """)

    for {sha, version, environment, valid?} <- [
          {"current-sha", "9.8.7", "prod", true},
          {"previous-release-sha", "9.8.7", "prod", false},
          {"current-sha", "9.8.6", "prod", false},
          {"current-sha", "9.8.7", "dev", false}
        ] do
      {output, status} =
        System.cmd("bash", ["-c", verify["run"]],
          cd: directory,
          stderr_to_stdout: true,
          env:
            [
              {"ERL_FLAGS", "+S 2:2"},
              {"FIXTURE_ELIXIR", System.find_executable("elixir")},
              {"FIXTURE_BUILD_INFO", build_info},
              {"FIXTURE_COMPILED_SHA", sha},
              {"FIXTURE_COMPILED_VERSION", version},
              {"FIXTURE_COMPILED_ENV", environment},
              {"GATED_SHA", "current-sha"},
              {"RELEASE_VERSION", "9.8.7"}
            ] ++ Enum.map(metadata_env, &{&1, "runtime-override"})
        )

      if valid? do
        assert status == 0, output
      else
        assert status != 0, "accepted stale metadata: #{inspect({sha, version, environment})}"
        assert output =~ "Release build metadata mismatch"
      end
    end
  end

  test "Docker allows deliberately skipped Hex only for selective successful releases" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    condition = workflow["jobs"]["docker-image"]["if"]
    results = ~w(success failure skipped cancelled)

    for selection <- ["all", Enum.join(@runtime_release_apps, ",")],
        publish <- results,
        hex <- results,
        cancelled <- [false, true] do
      expression =
        condition
        |> String.trim()
        |> String.replace_prefix("${{", "")
        |> String.replace_suffix("}}", "")
        |> String.replace("!cancelled()", to_string(!cancelled))
        |> String.replace("needs.publish.result", inspect(publish))
        |> String.replace("needs.hex-packages.result", inspect(hex))
        |> String.replace("needs.publish.outputs.release_apps", inspect(selection))
        |> String.replace("'success'", ~s("success"))
        |> String.replace("'skipped'", ~s("skipped"))
        |> String.replace("'all'", ~s("all"))

      {actual, []} = Code.eval_string(expression)

      expected =
        !cancelled and publish == "success" and
          (hex == "success" or (selection != "all" and hex == "skipped"))

      assert actual == expected,
             "selection=#{selection} publish=#{publish} hex=#{hex} cancelled=#{cancelled}"
    end
  end

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

  test "published agent runtime documents its JSON Schema production dependency" do
    package_mix = File.read!("apps/backplane_agent_runtime/mix.exs")

    assert package_mix =~ "{:jsonschex, \"~> 0.10.0\"}"
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
             ~s(mix "do" --app backplane_memory cmd mix test --exclude memory_qualification_runtime)
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

  defp version_fixture do
    directory =
      Path.join(
        System.tmp_dir!(),
        "backplane-release-version-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    for path <- ["mix.exs" | Path.wildcard("apps/*/mix.exs")] ++ @mcp_examples do
      destination = Path.join(directory, path)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(path, destination)
    end

    directory
  end

  defp version_snapshot(directory) do
    directory
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, directory), File.read!(path)} end)
  end

  defp set_version(directory, arguments) do
    System.cmd("bash", [Path.expand("scripts/set-version.sh") | arguments],
      cd: directory,
      stderr_to_stdout: true
    )
  end
end
