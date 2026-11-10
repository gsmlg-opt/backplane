ExUnit.start()

defmodule Backplane.ReleaseConfigTest do
  use ExUnit.Case, async: true

  @runtime_release_apps ~w(backplane_admin backplane_api backplane_host_agent backplane_llama backplane_memory backplane_skills backplane_system)
  @mcp_examples ~w(apps/backplane_mcp_protocol/README.md apps/backplane_mcp_protocol/pages/introduction.md apps/backplane_mcp_protocol/pages/building-a-server.md)
  @memory_plugins ~w(integrations/memory/hermes/plugin.yaml integrations/memory/openclaw/plugin.yaml integrations/memory/openclaw/package.json integrations/memory/openclaw/openclaw.plugin.json)

  test "memory plugin versions match the project version" do
    [_, version] = Regex.run(~r/@version "([^"]+)"/, File.read!("mix.exs"))

    for path <- @memory_plugins do
      assert plugin_version(path, File.read!(path)) == version, path
    end
  end

  test "version script preserves unified versioning by default and with explicit all" do
    for selection <- [[], ["all"]] do
      directory = version_fixture()
      {_output, 0} = set_version(directory, ["v9.8.7" | selection])
      snapshot = version_snapshot(directory)

      for {path, contents} <- snapshot do
        cond do
          path in @memory_plugins ->
            assert plugin_version(path, contents) == "9.8.7"

          String.ends_with?(path, "mix.exs") ->
            assert contents =~ ~r/@version\s+"9\.8\.7"/

          true ->
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
      cond do
        path in @memory_plugins ->
          assert plugin_version(path, after_snapshot[path]) == "9.8.7"

        path in selected ->
          assert after_snapshot[path] != contents
          assert after_snapshot[path] =~ ~r/@version\s+"9\.8\.7"/

        true ->
          assert after_snapshot[path] == contents, "unexpected change to #{path}"
      end
    end
  end

  test "selecting the MCP package updates its manifest, examples, root and memory plugins" do
    directory = version_fixture()
    before = version_snapshot(directory)
    {_output, 0} = set_version(directory, ["9.8.7", "backplane_mcp_protocol"])
    after_snapshot = version_snapshot(directory)

    selected =
      ["mix.exs", "apps/backplane_mcp_protocol/mix.exs" | @mcp_examples] ++ @memory_plugins

    for {path, contents} <- before do
      assert after_snapshot[path] != contents == path in selected, path
    end

    for path <- @memory_plugins do
      assert plugin_version(path, after_snapshot[path]) == "9.8.7"
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

  test "version script validates all manifests, plugins and selected examples before writing" do
    for broken_path <-
          ["apps/backplane_system/mix.exs", List.last(@mcp_examples)] ++ @memory_plugins do
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
    assert workflow =~ "release_apps: ${{ needs.prepare.outputs.release_apps }}"
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
      workflow["jobs"]["prepare"]["steps"]
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
        ~w(backplane_agent_runtime backplane_ai_protocol backplane_skill_protocol backplane_mcp_protocol backplane_schema),
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

  @tag :tmp_dir
  test "runtime package guard evaluates inactive branches and rejects active local dependencies and external paths",
       %{tmp_dir: directory} do
    script = File.read!("scripts/verify_agent_runtime_package.sh")
    [_, guard] = Regex.run(~r/<<'MANIFEST_GUARD'\n(.*?)\nMANIFEST_GUARD/s, script)
    guard_path = Path.join(directory, "guard.exs")
    File.write!(guard_path, guard)

    for {extra, accepted} <- [
          {"deps: if(false, do: [{:unused, path: \"../unused\", in_umbrella: true}], else: [])",
           true},
          {"deps: [{:local, path: \"../local\"}]", false},
          {"deps: [{:local, in_umbrella: true}]", false},
          {"build_path: \"../_build\"", false},
          {"deps_path: \"../deps\"", false},
          {"config_path: \"../config/config.exs\"", false},
          {"lockfile: \"../mix.lock\"", false},
          {"apps_path: \"../apps\"", false}
        ] do
      project = Path.join(directory, "project")
      File.mkdir_p!(project)

      File.write!(
        Path.join(project, "mix.exs"),
        "defmodule GuardFixture.MixProject do\nuse Mix.Project\ndef project, do: [app: :backplane_agent_runtime, version: \"0.1.0\", #{extra}]\nend\n"
      )

      {output, status} = System.cmd("elixir", [guard_path, project], stderr_to_stdout: true)

      if accepted,
        do: assert(status == 0, output),
        else: assert(status != 0, "accepted #{extra}: #{output}")
    end
  end

  test "runtime package dependency guard distinguishes protocol packages from server apps" do
    script = File.read!("scripts/verify_agent_runtime_package.sh")
    [_, expression] = Regex.run(~r/if grep -Eq '([^']+)' <<<"\$dependencies"/, script)

    for {dependency, rejected} <- [
          {"backplane_mcp_protocol ~> 1.10.32 (Hex package)", false},
          {"backplane_plugin_protocol ~> 1.10.32 (Hex package)", false},
          {"backplane_schema ~> 1.10.58 (Hex package)", false},
          {"backplane_mcp ~> 1.10.32", true},
          {"backplane_system ~> 1.10.32", true},
          {"phoenix_live_view ~> 1.0", true},
          {"ecto_sql ~> 3.0", true},
          {"postgrex ~> 1.0", true}
        ] do
      command = "printf '%s\\n' \"$DEPENDENCY\" | grep -Eq \"$EXPRESSION\""

      {_output, status} =
        System.cmd("sh", ["-c", command],
          env: [{"DEPENDENCY", "├── " <> dependency}, {"EXPRESSION", expression}]
        )

      assert status == 0 == rejected, dependency
    end
  end

  test "Linux releases build the optional PTY helper before assembling the package" do
    steps = YamlElixir.read_from_file!(".github/workflows/release.yml")["jobs"]["build"]["steps"]
    build = Enum.find(steps, &(&1["name"] == "Build optional Linux PTY helper"))
    assert build["if"] == "runner.os == 'Linux' && matrix.release == 'backplane'"
    assert build["run"] == "mix backplane.pty.build"
    refute File.read!("apps/backplane_host_agent/mix.exs") =~ "{:backplane_agent_runtime,"

    assert Enum.find_index(steps, &(&1 == build)) <
             Enum.find_index(steps, &(&1["name"] == "Build OTP release"))
  end

  test "gateway native releases and Docker build the MCP guardian before assembly" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    steps = workflow["jobs"]["build"]["steps"]
    build = Enum.find(steps, &(&1["name"] == "Build verified MCP stdio guardian"))
    assert build["if"] == "matrix.release == 'backplane'"
    assert build["run"] == "mix backplane.mcp.stdio.build"

    assert Enum.find_index(steps, &(&1 == build)) <
             Enum.find_index(steps, &(&1["name"] == "Build OTP release"))

    docker = File.read!("Dockerfile")
    assert docker =~ "RUN mix backplane.mcp.stdio.build"
    assert docker =~ "backplane_mcp_protocol-${VERSION}/priv/bin/backplane-mcp-stdio-guardian"

    packages = workflow["jobs"]["hex-packages"]
    assert "hex-mcp-protocol" in packages["needs"]
    names = Enum.map(packages["strategy"]["matrix"]["package"], & &1["name"])
    assert "backplane_agent_runtime" in names
    refute "backplane_mcp_protocol" in names

    mcp = workflow["jobs"]["hex-mcp-protocol"]
    assert mcp["needs"] == ["publish", "hex-plugin-protocol", "hex-schema"]
    assert mcp["if"] == "needs.publish.outputs.release_apps == 'all'"
    publish_mcp = Enum.find(mcp["steps"], &(&1["name"] == "Publish package"))
    assert publish_mcp["working-directory"] == "${{ env.PACKAGE_DIRECTORY }}"
    assert publish_mcp["run"] =~ "publish_hex_package.py"
  end

  test "release refreshes compiled admin metadata and checks inventory before archiving" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    build = workflow["jobs"]["build"]
    steps = build["steps"]
    refresh = Enum.find(steps, &(&1["name"] == "Refresh compiled admin build metadata"))
    inventory = Enum.find(steps, &(&1["name"] == "Check packaged release inventory"))

    assert refresh["if"] == "matrix.release == 'backplane'"

    assert refresh["run"] ==
             ~s(mix "do" --app backplane_admin loadpaths + compile.all --force --warnings-as-errors)

    assert build["env"]["GATED_SHA"] == "${{ needs.prepare.outputs.gated_sha }}"
    assert build["env"]["RELEASE_VERSION"] == "${{ needs.prepare.outputs.version }}"
    assert inventory["run"] =~ "_build/prod/rel/backplane/bin/backplane"
    assert inventory["run"] =~ "scripts/verify_web_assets.exs --release"

    positions =
      Enum.map(
        [
          "Import qualified web assets",
          "Refresh compiled admin build metadata",
          "Build OTP release",
          "Check packaged release inventory",
          "Archive OTP release"
        ],
        fn name -> Enum.find_index(steps, &(&1["name"] == name)) end
      )

    refute nil in positions
    assert positions == Enum.sort(positions)
  end

  @tag :tmp_dir
  test "release refresh selects admin while umbrella compilation preserves selected tests and root overrides",
       %{
         tmp_dir: directory
       } do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")

    refresh =
      workflow["jobs"]["build"]["steps"]
      |> Enum.find(&(&1["name"] == "Refresh compiled admin build metadata"))

    File.write!(Path.join(directory, "mix.exs"), """
    defmodule ReleaseScopeFixture.MixProject do
      use Mix.Project
      def project do
        [apps_path: "apps", version: "0.1.0",
         deps: [{:fixture_adapter, path: #{inspect(Path.join(directory, "deps/current_adapter"))}, override: true}]]
      end
    end
    """)

    for app <- ~w(backplane_admin fixture_system unrelated_app) do
      app_directory = Path.join([directory, "apps", app])
      File.mkdir_p!(Path.join(app_directory, "lib"))

      dependencies =
        case app do
          "backplane_admin" ->
            [
              {:fixture_system, in_umbrella: true},
              {:fixture_asset_builder, path: Path.join(directory, "deps/asset_builder")}
            ]

          "fixture_system" ->
            [
              {:fixture_adapter,
               path: Path.join(directory, "deps/current_adapter"), override: true}
            ]

          "unrelated_app" ->
            []
        end

      File.write!(Path.join(app_directory, "mix.exs"), """
      defmodule #{Macro.camelize(app)}.MixProject do
        use Mix.Project
        def project, do: [app: :#{app}, version: "0.1.0", build_path: "../../_build", deps: #{inspect(dependencies)}]
      end
      """)
    end

    for {name, app, dependencies} <- [
          {"current_adapter", :fixture_adapter, []},
          {"legacy_adapter", :fixture_adapter, []},
          {"asset_builder", :fixture_asset_builder,
           [{:fixture_adapter, path: Path.join(directory, "deps/legacy_adapter")}]}
        ] do
      dependency_directory = Path.join([directory, "deps", name])
      File.mkdir_p!(Path.join(dependency_directory, "lib"))

      File.write!(Path.join(dependency_directory, "mix.exs"), """
      defmodule #{Macro.camelize(name)}.MixProject do
        use Mix.Project
        def project, do: [app: :#{app}, version: "0.1.0", deps: #{inspect(dependencies)}]
      end
      """)

      if app == :fixture_adapter do
        File.write!(Path.join(dependency_directory, "lib/adapter.ex"), """
        defmodule FixtureTransportAdapter do
          def version, do: #{inspect(name)}
        end
        """)
      end
    end

    File.write!(Path.join(directory, "apps/backplane_admin/lib/metadata.ex"), """
    defmodule ReleaseMetadataFixture do
      @revision System.fetch_env!("FIXTURE_COMPILED_SHA")
      @adapter FixtureTransportAdapter.version()
      def revision, do: @revision
      def adapter, do: @adapter
    end
    """)

    env = [{"MIX_ENV", "prod"}, {"ERL_FLAGS", "+S 2:2"}, {"MIX_BUILD_PATH", nil}]

    {output, status} =
      System.cmd("mix", ["compile"],
        cd: directory,
        stderr_to_stdout: true,
        env: [{"FIXTURE_COMPILED_SHA", "previous-sha"} | env]
      )

    assert status == 0, output

    File.rm_rf!(Path.join(directory, "_build/prod/lib/unrelated_app"))

    File.write!(
      Path.join(directory, "apps/unrelated_app/lib/unrelated.ex"),
      ~s(raise "unrelated umbrella app must not be compiled by admin metadata refresh")
    )

    {output, status} =
      System.cmd("bash", ["-c", refresh["run"]],
        cd: directory,
        stderr_to_stdout: true,
        env: [{"FIXTURE_COMPILED_SHA", "current-sha"} | env]
      )

    assert status == 0, output
    refute File.dir?(Path.join(directory, "_build/prod/lib/unrelated_app/ebin"))

    {output, status} =
      System.cmd(
        "elixir",
        [
          "-pa",
          Path.join(directory, "_build/prod/lib/backplane_admin/ebin"),
          "-e",
          "IO.puts(ReleaseMetadataFixture.revision())"
        ],
        stderr_to_stdout: true,
        env: [{"FIXTURE_COMPILED_SHA", nil} | env]
      )

    assert status == 0, output
    assert String.trim(output) == "current-sha"

    {output, status} =
      System.cmd(
        "elixir",
        [
          "-pa",
          Path.join(directory, "_build/prod/lib/backplane_admin/ebin"),
          "-e",
          "IO.puts(ReleaseMetadataFixture.adapter())"
        ],
        stderr_to_stdout: true,
        env: env
      )

    assert status == 0, output
    assert String.trim(output) == "current_adapter"

    test_workflow = YamlElixir.read_from_file!(".github/workflows/test.yml")
    test_steps = test_workflow["jobs"]["test"]["steps"]

    compile = Enum.find(test_steps, &(&1["name"] == "Compile umbrella applications"))
    tests = Enum.find(test_steps, &(&1["name"] == "Run tests"))
    selected_app = "${{ matrix.app }}"
    test_env = List.keyreplace(env, "MIX_ENV", 0, {"MIX_ENV", "test"})
    test_env = [{"FIXTURE_COMPILED_SHA", "current-sha"} | test_env]

    File.rm!(Path.join(directory, "apps/unrelated_app/lib/unrelated.ex"))

    {output, status} =
      System.cmd("bash", ["-c", String.replace(compile["run"], selected_app, "backplane_admin")],
        cd: directory,
        stderr_to_stdout: true,
        env: test_env
      )

    assert status == 0, output

    assert File.regular?(
             Path.join(directory, "_build/test/lib/unrelated_app/ebin/unrelated_app.app")
           )

    unrelated_tests = Path.join(directory, "apps/unrelated_app/test")
    File.mkdir_p!(unrelated_tests)

    File.write!(
      Path.join(unrelated_tests, "test_helper.exs"),
      ~s(raise "unrelated umbrella app tests must not run")
    )

    test_directory = Path.join(directory, "apps/backplane_admin/test")
    File.mkdir_p!(test_directory)
    File.write!(Path.join(test_directory, "test_helper.exs"), "ExUnit.start()")
    test_file = Path.join(test_directory, "adapter_test.exs")

    File.write!(test_file, """
    defmodule AdapterTest do
      use ExUnit.Case
      test "uses the root adapter", do: assert(ReleaseMetadataFixture.adapter() == "current_adapter")
    end
    """)

    test_command = String.replace(tests["run"], selected_app, "backplane_admin")

    {output, status} =
      System.cmd("bash", ["-c", test_command],
        cd: directory,
        stderr_to_stdout: true,
        env: test_env
      )

    assert status == 0, output
    assert output =~ "1 test, 0 failures"

    File.write!(test_file, String.replace(File.read!(test_file), "==", "!="))

    {output, status} =
      System.cmd("bash", ["-c", test_command],
        cd: directory,
        stderr_to_stdout: true,
        env: test_env
      )

    assert status != 0, "test command ignored assertion failure: #{output}"
    assert output =~ "1 test, 1 failure"

    File.write!(
      Path.join(directory, "apps/backplane_admin/lib/metadata.ex"),
      ~s(raise "admin metadata compile failure")
    )

    {output, status} =
      System.cmd("bash", ["-c", refresh["run"]],
        cd: directory,
        stderr_to_stdout: true,
        env: env
      )

    assert status != 0, "metadata refresh ignored compiler failure: #{output}"
    assert output =~ "admin metadata compile failure"
  end

  test "test workflow cleans stale sibling application metadata without discarding dependency builds" do
    steps = YamlElixir.read_from_file!(".github/workflows/test.yml")["jobs"]["test"]["steps"]
    clean = Enum.find(steps, &(&1["name"] == "Clean cached umbrella applications"))
    compile = Enum.find(steps, &(&1["name"] == "Compile umbrella applications"))
    tests = Enum.find(steps, &(&1["name"] == "Run tests"))

    directory =
      Path.join(System.tmp_dir!(), "backplane-stale-app-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    write = fn path, contents ->
      path = Path.join(directory, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    write.("mix.exs", """
    defmodule StaleAppsFixture.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps"]
    end
    """)

    for {app, dependencies} <- [
          {"removed_transport", "[]"},
          {"sibling", "[{:removed_transport, in_umbrella: true}]"},
          {"selected",
           ~s([{:sibling, in_umbrella: true}, {:external_fixture, path: "../../deps/external_fixture"}])},
          {"unrelated", "[]"}
        ] do
      write.("apps/#{app}/mix.exs", """
      defmodule #{Macro.camelize(app)}.MixProject do
        use Mix.Project
        def project, do: [app: :#{app}, version: "1.0.0", build_path: "../../_build", deps: #{dependencies}]
      end
      """)
    end

    write.("deps/external_fixture/mix.exs", """
    defmodule ExternalFixture.MixProject do
      use Mix.Project
      def project, do: [app: :external_fixture, version: "1.0.0"]
    end
    """)

    write.("apps/sibling/lib/entity.ex", """
    defmodule Sibling.Entity do
      defstruct value: 2
    end
    """)

    write.("apps/selected/lib/current.ex", """
    defmodule Selected.Current do
      def entity, do: %Sibling.Entity{}
    end
    """)

    write.("apps/selected/test/test_helper.exs", "ExUnit.start()")

    write.("apps/selected/test/selected_test.exs", """
    defmodule SelectedTest do
      use ExUnit.Case
      test "starts with current sibling metadata" do
        assert Application.spec(:sibling, :vsn) == ~c"2.0.0"
        refute :removed_transport in Application.spec(:sibling, :applications)
        assert Selected.Current.entity().value == 2
      end
    end
    """)

    write.("apps/unrelated/test/test_helper.exs", ~s(raise "unrelated tests must not run"))
    env = [{"MIX_ENV", "test"}, {"ERL_FLAGS", "+S 2:2"}, {"MIX_BUILD_PATH", nil}]

    run = fn command ->
      System.cmd("bash", ["-c", command], cd: directory, stderr_to_stdout: true, env: env)
    end

    {output, status} = run.("mix compile")
    assert status == 0, output
    sibling_app = Path.join(directory, "_build/test/lib/sibling/ebin/sibling.app")
    stale_app = File.read!(sibling_app)

    external_app =
      Path.join(directory, "_build/test/lib/external_fixture/ebin/external_fixture.app")

    external_build = File.read!(external_app)
    sibling_mix = Path.join(directory, "apps/sibling/mix.exs")

    File.write!(
      sibling_mix,
      sibling_mix
      |> File.read!()
      |> String.replace("1.0.0", "2.0.0")
      |> String.replace("[{:removed_transport, in_umbrella: true}]", "[]")
    )

    File.rm_rf!(Path.join(directory, "apps/removed_transport"))
    File.rm_rf!(Path.join(directory, "_build/test/lib/removed_transport"))

    # A restored build can be newer than checkout sources, including changed Mixfiles.
    File.touch!(sibling_mix, {{2000, 1, 1}, {0, 0, 0}})
    File.touch!(sibling_app, System.os_time(:second) + 60)

    compile_command = String.replace(compile["run"], "${{ matrix.app }}", "selected")
    test_command = String.replace(tests["run"], "${{ matrix.app }}", "selected")

    {output, status} = run.(compile_command)
    assert status == 0, output
    assert File.read!(sibling_app) == stale_app
    {output, status} = run.(test_command)
    assert status != 0, output
    assert output =~ "Could not start application removed_transport"
    assert File.read!(sibling_app) == stale_app

    # Clean all umbrella builds, then prove the struct dependency compiles from cold.
    {output, status} = run.(clean["run"])
    assert status == 0, output
    refute File.exists?(sibling_app)

    refute File.exists?(
             Path.join(directory, "_build/test/lib/selected/ebin/Elixir.Selected.Current.beam")
           )

    assert File.read!(external_app) == external_build
    assert File.regular?(Path.join(directory, "deps/external_fixture/mix.exs"))
    {output, status} = run.(compile_command)
    assert status == 0, output
    {output, status} = run.(test_command)
    assert status == 0, output
    assert output =~ "1 test, 0 failures"
    refute output =~ "unrelated tests must not run"
    refute File.read!(sibling_app) =~ "removed_transport"
    assert File.read!(sibling_app) =~ ~s({vsn,"2.0.0"})
    refute File.exists?(Path.join(directory, "_build/test/lib/removed_transport"))
  end

  @tag :tmp_dir
  test "static package inventory rejects stale versions and missing required files", %{
    tmp_dir: directory
  } do
    steps = YamlElixir.read_from_file!(".github/workflows/release.yml")["jobs"]["build"]["steps"]
    inventory = Enum.find(steps, &(&1["name"] == "Check packaged release inventory"))
    release = Path.join(directory, "_build/prod/rel/backplane")
    File.mkdir_p!(Path.join(release, "releases/9.8.7"))
    File.mkdir_p!(Path.join(directory, "scripts"))
    File.write!(Path.join(directory, "scripts/verify_web_assets.exs"), ":ok\n")

    files = [
      "bin/backplane",
      "lib/backplane_agent_runtime-9.8.7/priv/bin/backplane-local-command-pty",
      "lib/backplane_mcp_protocol-9.8.7/priv/bin/backplane-mcp-stdio-guardian"
    ]

    for path <- files do
      path = Path.join(release, path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    manifests =
      for app <- ~w(backplane backplane_admin) do
        path = Path.join(release, "lib/#{app}-9.8.7/ebin/#{app}.app")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "{application,#{app},[{vsn,\"9.8.7\"}]}.\n")
        path
      end

    run = fn ->
      System.cmd("bash", ["-e", "-o", "pipefail", "-c", inventory["run"]],
        cd: directory,
        stderr_to_stdout: true,
        env: [{"RELEASE_VERSION", "9.8.7"}, {"RELEASE_APPS", "all"}, {"ERL_FLAGS", "+S 2:2"}]
      )
    end

    {output, status} = run.()
    assert status == 0, output

    for path <- files do
      path = Path.join(release, path)
      File.chmod!(path, 0o644)
      {_output, status} = run.()
      assert status != 0, "accepted non-executable required file #{path}"
      File.chmod!(path, 0o755)
    end

    [manifest | _] = manifests
    valid = File.read!(manifest)
    File.write!(manifest, String.replace(valid, "9.8.7", "9.8.6"))
    {output, status} = run.()
    assert status != 0
    assert output =~ "Packaged application version mismatch"
    File.write!(manifest, valid)

    for manifest <- manifests, do: File.rm!(manifest)
    {_output, status} = run.()
    assert status != 0, "accepted a release missing required application manifests"
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
    assert releases[:backplane][:applications][:backplane_agent_runtime] == :permanent
    refute Keyword.has_key?(releases[:backplane][:applications], :backplane_host_agent)

    assert releases[:host_agent][:applications][:backplane_host_agent] == :permanent
    assert releases[:host_agent][:runtime_config_path] == "config/host_agent_runtime.exs"
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane)
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane_api)
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane_admin)
    refute Keyword.has_key?(releases[:host_agent][:applications], :backplane_agent_runtime)
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

  @tag :host_agent_distribution
  test "host agent release defaults to no distribution and disables automatic epmd" do
    assert {"none\n-start_epmd false\n", 0} = release_environment("host_agent")
  end

  @tag :host_agent_distribution
  test "host agent epmd options preserve runtime flags and repeated sourcing is idempotent" do
    for options <- ["+S 2:2", "+S 2:2 -start_epmd false"] do
      assert {"none\n+S 2:2 -start_epmd false\n", 0} =
               release_environment("host_agent", nil, options)
    end
  end

  @tag :host_agent_distribution
  test "host agent preserves an explicitly configured distribution mode" do
    assert {"name\n+S 2:2 -start_epmd false\n", 0} =
             release_environment("host_agent", "name", "+S 2:2")
  end

  @tag :host_agent_distribution
  test "gateway release environment retains its existing distribution and runtime options" do
    assert {"\n\n", 0} = release_environment("backplane")
    assert {"name\n+S 2:2\n", 0} = release_environment("backplane", "name", "+S 2:2")
  end

  test "root mix release is an alias for building both configured releases" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert is_function(aliases[:release], 1)
  end

  test "root asset deploy runs the isolated web asset orchestrator" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert is_function(aliases[:"assets.deploy"], 1)
  end

  test "build and release workflows verify packaged assets without executing release test code" do
    for path <- [".github/workflows/build.yml", ".github/workflows/release.yml"] do
      workflow = File.read!(path)

      assert workflow =~
               "elixir -pa _build/prod/lib/jason/ebin scripts/verify_web_assets.exs --release _build/prod/rel/backplane"

      refute workflow =~ ~s(mix "do" --app backplane_api assets.deploy)
      refute workflow =~ ~s(mix "do" --app backplane_admin assets.deploy)
    end

    release = File.read!(".github/workflows/release.yml")
    refute release =~ "elixir test/build_web_assets_script_test.exs"
    refute release =~ "scripts/verify_web_assets_http.py"
    refute release =~ "installed/backplane/bin/backplane daemon"
    refute release =~ "installed-release-migration-smoke:"
  end

  test "gateway releases build shared static assets once on the supported platform" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    producer = workflow["jobs"]["web-assets"]
    build = workflow["jobs"]["build"]

    export =
      Enum.find(
        producer["steps"],
        &String.contains?(&1["run"] || "", "--export . artifacts/web-assets")
      )

    upload = Enum.find(producer["steps"], &(&1["with"]["name"] == "qualified-web-assets"))
    download = Enum.find(build["steps"], &(&1["with"]["name"] == "qualified-web-assets"))

    import =
      Enum.find(
        build["steps"],
        &String.contains?(&1["run"] || "", "--import artifacts/web-assets")
      )

    assert producer["runs-on"] == "ubuntu-26.04"
    assert producer["needs"] == "prepare"
    assert export["env"]["GATED_SHA"] == "${{ needs.prepare.outputs.gated_sha }}"
    assert export["env"]["RELEASE_VERSION"] == "${{ needs.prepare.outputs.version }}"
    assert export["env"]["DUSKMOON_NATIVE_MODE"] == "precompiled"
    assert export["run"] =~ "mix assets.deploy"
    assert export["run"] =~ ~s(--export . artifacts/web-assets "$GATED_SHA" "$RELEASE_VERSION")
    assert upload["with"]["path"] == "artifacts/web-assets/"
    assert upload["with"]["if-no-files-found"] == "error"
    assert upload["with"]["name"] == download["with"]["name"]
    assert import["run"] =~ ~s(--import artifacts/web-assets . "$GATED_SHA" "$RELEASE_VERSION")
    assert Enum.sort(List.wrap(build["needs"])) == ["prepare", "web-assets"]
    refute Enum.any?(build["steps"], &String.contains?(&1["run"] || "", "mix assets.deploy"))

    assert Enum.map(build["strategy"]["matrix"]["include"], & &1["target"]["runner"]) ==
             ["ubuntu-24.04", "ubuntu-24.04-arm"]

    assert Enum.all?(build["strategy"]["matrix"]["include"], &(&1["release"] == "backplane"))

    download =
      Enum.find(
        workflow["jobs"]["publish"]["steps"],
        &(&1["name"] == "Download release artifacts")
      )

    assert download["with"] == %{
             "pattern" => "backplane-*",
             "path" => "dist",
             "merge-multiple" => true
           }

    build_workflow = YamlElixir.read_from_file!(".github/workflows/build.yml")
    steps = build_workflow["jobs"]["otp-release"]["steps"]
    isolated = Enum.find(steps, &(&1["name"] == "Build isolated web assets"))
    assert isolated["if"] == "matrix.release == 'backplane'"
    assert isolated["run"] =~ "docker buildx build --target web-assets"
    assert isolated["run"] =~ "--import artifacts/web-assets"

    docker = Enum.find(steps, &(&1["name"] == "Verify retained Bookworm Docker release builder"))
    assert docker["if"] == "matrix.release == 'backplane' && matrix.target.name == 'linux-x64'"
    assert docker["run"] =~ "docker buildx build --target builder"
    assert docker["run"] =~ "--output type=cacheonly"
    assert Enum.find_index(steps, &(&1 == docker)) < Enum.find_index(steps, &(&1 == isolated))
    refute Enum.any?(steps, &String.contains?(&1["run"] || "", "mix assets.deploy"))
  end

  test "host agent release step copies integrations with the release version and preserves sources" do
    host_agent =
      Mix.Project.config()
      |> Keyword.fetch!(:releases)
      |> Keyword.fetch!(:host_agent)

    refute Keyword.has_key?(host_agent, :overlays)
    assert [:assemble, copy_integrations] = host_agent[:steps]
    assert is_function(copy_integrations, 1)

    directory =
      Path.join(System.tmp_dir!(), "backplane-host-agent-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    release = %Mix.Release{
      path: directory,
      version: "9.8.7-rc.1+build.2",
      applications: %{backplane_host_agent: [vsn: ~c"1.2.3"]}
    }

    sources = version_snapshot("integrations/memory")

    assert copy_integrations.(release) == release

    destination =
      Path.join([
        directory,
        "lib",
        "backplane_host_agent-1.2.3",
        "priv/integrations/memory"
      ])

    packaged = version_snapshot(destination)
    assert Map.keys(packaged) |> Enum.sort() == Map.keys(sources) |> Enum.sort()

    for {path, contents} <- sources do
      if "integrations/memory/#{path}" in @memory_plugins do
        assert plugin_version(path, packaged[path]) == release.version, path

        assert Map.delete(plugin_manifest(path, packaged[path]), "version") ==
                 Map.delete(plugin_manifest(path, contents), "version"),
               path
      else
        assert packaged[path] == contents, path
      end
    end

    assert version_snapshot("integrations/memory") == sources
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
          "backplane_skill_protocol"
        ] do
      assert release_workflow =~ "name: #{package}"
      assert release_workflow =~ "Publish ${{ matrix.package.name }} to Hex"
    end

    assert release_workflow =~ "name: Publish backplane_mcp_protocol to Hex"

    assert release_workflow =~ "Install package publishing dependencies"
    assert release_workflow =~ "Verify package documentation"
    assert release_workflow =~ "mix docs"
    assert release_workflow =~ "publish_hex_package.py"
    assert release_workflow =~ ~r/docker-image:.*needs:.*hex-packages/s
  end

  test "published agent runtime documents its JSON Schema production dependency" do
    package_mix = File.read!("apps/backplane_agent_runtime/mix.exs")

    assert package_mix =~ "protocol_dependency(:backplane_json_schema)"
    assert package_mix =~ "{:ex_doc, \">= 0.0.0\", only: [:dev, :test], runtime: false}"
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

  test "independent plugin qualification retains pinned OpenClaw contracts" do
    steps = workflow_steps(".github/workflows/memory-plugins.yml")
    setup = Enum.find(steps, &(&1["name"] == "Set up qualified OpenClaw Node runtime"))
    assert setup["uses"] == "actions/setup-node@v6"
    assert setup["with"] == %{"node-version" => "24.22.1"}

    contract = Enum.find(steps, &(&1["name"] == "Verify OpenClaw provider contract"))
    assert contract["run"] == "node --test integrations/memory/tests/test_openclaw*.mjs"

    lifecycle = Enum.find(steps, &(&1["name"] == "Verify memory plugin source lifecycle"))
    assert lifecycle["run"] =~ "openclaw_capture_contract_test.exs"
    assert lifecycle["run"] =~ "openclaw_hook_test.exs"
    packaged = Enum.find(steps, &(&1["name"] == "Verify packaged OpenClaw provider"))
    assert packaged["run"] =~ "backplane_host_agent-*/priv/integrations/memory"
    assert packaged["run"] =~ ~s(node --test "${roots[0]}"/tests/test_openclaw*.mjs)

    for path <- [".github/workflows/release.yml", ".github/workflows/host-agent-release.yml"] do
      commands = workflow_steps(path) |> Enum.map_join("\n", &(&1["run"] || ""))
      refute commands =~ "node --test"
      refute commands =~ "test_hermes"
      refute commands =~ "openclaw_memory_live_acceptance"
    end
  end

  @tag :tmp_dir
  test "qualification compiles and installs pgvector with the PostgreSQL 17 toolchain", %{
    tmp_dir: directory
  } do
    steps = workflow_steps(".github/workflows/memory-test.yml")
    setup = Enum.find(steps, &(&1["name"] == "Start PostgreSQL 17 with pgvector"))

    commands =
      setup["run"]
      |> String.split("\n", trim: true)
      |> Enum.filter(&Regex.match?(~r/^(sudo )?make -C \/tmp\/pgvector\b/, &1))

    assert commands == [
             "make -C /tmp/pgvector PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config with_llvm=no",
             "sudo make -C /tmp/pgvector PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config with_llvm=no install"
           ]

    assert setup["run"] =~ "postgresql-17 postgresql-server-dev-17"
    assert setup["run"] =~ "sudo pg_createcluster 17 main --start --port 5432"

    bin = Path.join(directory, "bin")
    log = Path.join(directory, "make-calls.log")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "make"), ~S"""
    #!/bin/sh
    printf '%s\n' "$*" >> "$PGVECTOR_MAKE_CALLS"
    """)

    File.write!(Path.join(bin, "sudo"), "#!/bin/sh\nexec env -u PG_CONFIG \"$@\"\n")
    for command <- ~w(make sudo), do: File.chmod!(Path.join(bin, command), 0o755)

    {output, status} =
      System.cmd("bash", ["-e", "-c", Enum.join(commands, "\n")],
        env: [
          {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
          {"PG_CONFIG", "/wrong/default/postgresql/18/bin/pg_config"},
          {"PGVECTOR_MAKE_CALLS", log}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert File.read!(log) |> String.split("\n", trim: true) == [
             "-C /tmp/pgvector PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config with_llvm=no",
             "-C /tmp/pgvector PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config with_llvm=no install"
           ]
  end

  test "server memory CI runs the Memory app suite outside release" do
    workflow = File.read!(".github/workflows/memory-test.yml")

    assert workflow =~ "mix test apps/backplane_memory/test"
    refute workflow =~ "mix do --app"
    refute workflow =~ "memory_slots"
    refute workflow =~ "edge_cutover_check"
    refute workflow =~ "mix memory.qualify"
    assert Backplane.Repo.config()[:pool_size] >= 10
    assert workflow =~ "postgresql-17"
    assert workflow =~ "CREATE EXTENSION IF NOT EXISTS vector"

    release = File.read!(".github/workflows/release.yml")
    refute release =~ "qualify-memory:"
    refute release =~ "mix memory.qualify"
    refute release =~ "mix ecto.migrate"
    refute release =~ "installed-release-migration-smoke:"

    for path <- [
          "docs/operations/memory.md",
          "docs/deploy/memory-release.md",
          "docs/qualification/memory.md",
          "docs/memory/host-memory-protocol.md",
          "docs/operations/host-memory-edge-runbook.md"
        ] do
      assert File.regular?(path), "missing release runbook #{path}"
      assert release =~ path
    end
  end

  test "GitHub test workflow runs every app suite without exclusions" do
    workflow = File.read!(".github/workflows/test.yml")

    assert workflow =~ ~s(mix "do" --app ${{ matrix.app }} test)
    refute workflow =~ "memory_qualification_runtime"
  end

  test "release integrity prepares one main-branch version SHA before builds" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    prepare = workflow["jobs"]["prepare"]
    gate = Enum.find(prepare["steps"], &(&1["id"] == "gate"))
    version = Enum.find(prepare["steps"], &(&1["id"] == "version"))

    assert prepare["name"] == "Check release integrity"
    assert prepare["outputs"]["gated_sha"] == "${{ steps.version.outputs.sha }}"
    assert prepare["outputs"]["version"] == "${{ steps.gate.outputs.version }}"
    assert gate["env"]["WORKFLOW_REF"] == "${{ github.ref }}"
    assert gate["env"]["RELEASE_VERSION_INPUT"] == "${{ inputs.version }}"
    assert gate["run"] =~ ~s([[ "$WORKFLOW_REF" != "refs/heads/main" ]])
    assert gate["run"] =~ "^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)"
    assert version["run"] =~ "git push origin HEAD:refs/heads/main"

    release = File.read!(".github/workflows/release.yml")
    assert release =~ "ref: ${{ needs.prepare.outputs.gated_sha }}"

    stage =
      Enum.find(
        workflow["jobs"]["publish"]["steps"],
        &(&1["name"] == "Stage immutable release assets")
      )

    assert stage["env"]["RELEASE_REVISION"] == "${{ needs.prepare.outputs.gated_sha }}"
    assert stage["run"] =~ "manage_release_assets.py stage"
    refute release =~ "inputs.git_ref"
    refute release =~ "needs.qualify-memory"

    refute Enum.any?(workflow["jobs"]["publish"]["steps"], fn step ->
             String.contains?(step["run"] || "", "git push")
           end)
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

  defp workflow_steps(path) do
    YamlElixir.read_from_file!(path)["jobs"]
    |> Map.values()
    |> Enum.flat_map(&(&1["steps"] || []))
  end

  defp version_fixture do
    directory =
      Path.join(
        System.tmp_dir!(),
        "backplane-release-version-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    for path <-
          ["mix.exs" | Path.wildcard("apps/*/mix.exs")] ++ @mcp_examples ++ @memory_plugins do
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

  defp plugin_version(path, contents) do
    plugin_manifest(path, contents)["version"]
  end

  defp plugin_manifest(path, contents) do
    if String.ends_with?(path, ".json") do
      Jason.decode!(contents)
    else
      YamlElixir.read_from_string!(contents)
    end
  end

  defp set_version(directory, arguments) do
    System.cmd("bash", [Path.expand("scripts/set-version.sh") | arguments],
      cd: directory,
      stderr_to_stdout: true
    )
  end

  defp release_environment(name, distribution \\ nil, options \\ nil) do
    System.cmd(
      "sh",
      [
        "-c",
        ~S(. "$1"; . "$1"; printf '%s\n%s\n' "${RELEASE_DISTRIBUTION-}" "${ELIXIR_ERL_OPTIONS-}"),
        "release-environment-test",
        Path.expand("rel/env.sh.eex")
      ],
      env: [
        {"RELEASE_NAME", name},
        {"RELEASE_COMMAND", "start"},
        {"RELEASE_DISTRIBUTION", distribution},
        {"ELIXIR_ERL_OPTIONS", options}
      ],
      stderr_to_stdout: true
    )
  end
end
