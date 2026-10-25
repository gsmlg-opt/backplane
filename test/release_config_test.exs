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
            assert contents =~ ~r/(?:@version\s+|version:\s*)"9\.8\.7"/

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
          assert after_snapshot[path] =~ ~r/(?:@version\s+|version:\s*)"9\.8\.7"/

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
             ~s(mix "do" --app backplane_admin loadpaths + compile.all --force --warnings-as-errors)

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

  test "release qualification gates the Hermes semantic oracle before database setup" do
    workflow = YamlElixir.read_from_file!(".github/workflows/release.yml")
    steps = workflow["jobs"]["qualify-memory-v2"]["steps"]
    name = "Verify Hermes live semantic oracle"

    assert [step] = Enum.filter(steps, &(&1["name"] == name))

    assert step == %{
             "name" => name,
             "run" => "MIX_ENV=test mix run --no-start test/hermes_memory_live_oracle_test.exs"
           }

    assert Enum.find_index(steps, &(&1["name"] == "Install dependencies")) <
             Enum.find_index(steps, &(&1["name"] == name))

    assert Enum.find_index(steps, &(&1["name"] == name)) <
             Enum.find_index(steps, &(&1["name"] == "Prepare qualification database"))
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
    assert workflow =~ "apps/backplane_memory/test/backplane/memory/fact_extraction_test.exs"
    assert workflow =~ "apps/backplane_memory/test/backplane/memory/llm_test.exs"
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
             ~s(mix "do" --app backplane_memory test --exclude memory_qualification_runtime)
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
