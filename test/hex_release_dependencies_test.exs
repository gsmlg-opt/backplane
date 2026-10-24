ExUnit.start()

defmodule Backplane.HexReleaseDependenciesTest do
  use ExUnit.Case, async: true

  @packages ~w(backplane_agent_runtime backplane_ai_protocol backplane_skill_protocol backplane_mcp_protocol)

  test "release and qualified recovery publish the plugin dependency before every consumer" do
    for {path, gate} <- [
          {".github/workflows/release.yml", "publish"},
          {".github/workflows/publish-hex.yml", "qualify"}
        ] do
      jobs = YamlElixir.read_from_file!(path)["jobs"]
      plugin = jobs["hex-plugin-protocol"]
      assert is_map(plugin), "#{path} must publish the runtime's plugin dependency first"
      assert gate in List.wrap(plugin["needs"])
      assert Enum.sort(jobs["hex-packages"]["needs"]) == Enum.sort([gate, "hex-plugin-protocol"])

      if gate == "publish" do
        assert Enum.map(jobs["hex-packages"]["strategy"]["matrix"]["package"], & &1["name"]) ==
                 @packages
      else
        assert jobs["hex-packages"]["strategy"]["matrix"] ==
                 "${{ fromJSON(needs.qualify.outputs.package_matrix) }}"
      end

      checkout = Enum.find(plugin["steps"], &(&1["uses"] == "actions/checkout@v7"))
      assert checkout["with"]["ref"] == "${{ needs.#{gate}.outputs.gated_sha }}"

      for {name, command} <- [
            {"Install package publishing dependencies", "mix deps.get"},
            {"Verify package documentation", "mix docs"},
            {"Publish package", "mix hex.publish --yes"}
          ] do
        step = Enum.find(plugin["steps"], &(&1["name"] == name))
        assert step["working-directory"] == "apps/backplane_plugin_protocol"
        assert step["run"] == command
      end

      validation = Enum.find(plugin["steps"], &(&1["name"] == "Validate package version"))
      assert validation["env"]["RELEASE_VERSION"] == "${{ needs.#{gate}.outputs.version }}"
      assert validation["run"] =~ ~s("$package_version" != "$RELEASE_VERSION")
    end
  end

  test "full release gates plugin publication and excludes it from selective runtime releases" do
    jobs = YamlElixir.read_from_file!(".github/workflows/release.yml")["jobs"]
    assert jobs["hex-plugin-protocol"]["if"] == "needs.publish.outputs.release_apps == 'all'"
    assert "hex-packages" in jobs["docker-image"]["needs"]

    gate = Enum.find(jobs["qualify-memory-v2"]["steps"], &(&1["id"] == "gate"))
    assert gate["run"] =~ "backplane_plugin_protocol|"

    assert Enum.any?(jobs["qualify-memory-v2"]["steps"], fn step ->
             step["run"] == "mix run --no-start test/hex_release_dependencies_test.exs"
           end)
  end

  test "qualified recovery handles releases predating the plugin package without substituting sources" do
    workflow = YamlElixir.read_from_file!(".github/workflows/publish-hex.yml")
    steps = workflow["jobs"]["hex-plugin-protocol"]["steps"]
    check = Enum.find(steps, &(&1["id"] == "package"))
    assert is_map(check)

    directory = temporary_directory()
    output = Path.join(directory, "output")

    for present? <- [false, true] do
      if present? do
        File.mkdir_p!(Path.join(directory, "apps/backplane_plugin_protocol"))
        File.write!(Path.join(directory, "apps/backplane_plugin_protocol/mix.exs"), "fixture")
      end

      File.write!(output, "")

      {log, status} =
        System.cmd("bash", ["-c", check["run"]],
          cd: directory,
          env: [{"GITHUB_OUTPUT", output}, {"PACKAGE_SELECTION", "all"}],
          stderr_to_stdout: true
        )

      assert status == 0, log
      assert File.read!(output) == "present=#{present?}\n"
    end

    File.write!(output, "")

    {log, status} =
      System.cmd("bash", ["-c", check["run"]],
        cd: directory,
        env: [{"GITHUB_OUTPUT", output}, {"PACKAGE_SELECTION", "backplane_agent_runtime"}],
        stderr_to_stdout: true
      )

    assert status == 0, log
    assert File.read!(output) == "present=false\n"

    for step <- Enum.drop_while(steps, &(&1["id"] != "package")) |> tl() do
      assert step["if"] == "steps.package.outputs.present == 'true'"
    end

    verifier = workflow["jobs"]["qualify"]["steps"] |> Enum.find(&(&1["id"] == "gate"))
    assert verifier["run"] =~ "python3 scripts/verify_qualified_hex_publication.py"
    refute Enum.any?(steps, &(&1["run"] && &1["run"] =~ "set-version.sh"))
  end

  test "qualified recovery restricts publication to all packages or runtime alone" do
    workflow = YamlElixir.read_from_file!(".github/workflows/publish-hex.yml")
    selection = workflow["on"]["workflow_dispatch"]["inputs"]["packages"]
    assert selection["type"] == "choice"
    assert selection["default"] == "all"
    assert selection["options"] == ["all", "backplane_agent_runtime"]

    qualify = workflow["jobs"]["qualify"]
    assert qualify["outputs"]["package_matrix"] == "${{ steps.packages.outputs.matrix }}"
    step = Enum.find(qualify["steps"], &(&1["id"] == "packages"))
    directory = temporary_directory()
    output = Path.join(directory, "output")

    for {selection, expected} <- [
          {"all", @packages},
          {"backplane_agent_runtime", ["backplane_agent_runtime"]}
        ] do
      File.write!(output, "")

      {log, status} =
        System.cmd("bash", ["-e", "-o", "pipefail", "-c", step["run"]],
          env: [{"GITHUB_OUTPUT", output}, {"PACKAGE_SELECTION", selection}],
          stderr_to_stdout: true
        )

      assert status == 0, log
      assert log =~ "Selected Hex packages: #{selection}"
      "matrix=" <> matrix = File.read!(output)

      assert Jason.decode!(matrix)["package"] ==
               Enum.map(expected, &%{"name" => &1, "path" => "apps/#{&1}"})
    end

    File.write!(output, "")

    {log, status} =
      System.cmd("bash", ["-e", "-o", "pipefail", "-c", step["run"]],
        env: [{"GITHUB_OUTPUT", output}, {"PACKAGE_SELECTION", "backplane_mcp_protocol"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert log =~ "Unsupported package selection"
    assert File.read!(output) == ""
  end

  test "both publication workflows stage unchanged runtime sources outside the umbrella" do
    workspace = File.cwd!()
    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    revision = String.trim(revision)
    package_path = "apps/backplane_agent_runtime"

    {tracked, 0} =
      System.cmd("git", ["ls-tree", "-r", "--name-only", "#{revision}:#{package_path}"])

    files = String.split(tracked, "\n", trim: true)
    assert files != []

    for {path, gate} <- [
          {".github/workflows/release.yml", "publish"},
          {".github/workflows/publish-hex.yml", "qualify"}
        ] do
      steps = YamlElixir.read_from_file!(path)["jobs"]["hex-packages"]["steps"]
      stage = Enum.find(steps, &(&1["name"] == "Select package working directory"))
      assert stage["env"]["GATED_SHA"] == "${{ needs.#{gate}.outputs.gated_sha }}"

      for name <- [
            "Validate package version",
            "Install package publishing dependencies",
            "Verify package documentation",
            "Publish package"
          ] do
        assert Enum.find(steps, &(&1["name"] == name))["working-directory"] ==
                 "${{ env.PACKAGE_DIRECTORY }}"
      end

      for name <- ["Restore Mix cache", "Install dependencies"] do
        assert Enum.find(steps, &(&1["name"] == name))["if"] ==
                 "matrix.package.name != 'backplane_agent_runtime'"
      end

      directory = temporary_directory()
      output = Path.join(directory, "env")

      {log, status} =
        System.cmd("bash", ["-e", "-o", "pipefail", "-c", stage["run"]],
          cd: workspace,
          env: [
            {"GATED_SHA", revision},
            {"PACKAGE_NAME", "backplane_agent_runtime"},
            {"PACKAGE_PATH", package_path},
            {"GITHUB_WORKSPACE", workspace},
            {"RUNNER_TEMP", directory},
            {"GITHUB_ENV", output}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, log
      assert log =~ "QUALIFIED_HEX_SOURCE_REVISION=#{revision}"
      assert log =~ "QUALIFIED_HEX_PACKAGE=backplane_agent_runtime"
      assert log =~ "QUALIFIED_HEX_STANDALONE=true"
      "PACKAGE_DIRECTORY=" <> package_directory = File.read!(output)
      package_directory = String.trim(package_directory)
      assert String.starts_with?(package_directory, directory <> "/")
      refute File.dir?(Path.expand("../../apps", package_directory))

      staged_files =
        package_directory
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, package_directory))
        |> Enum.sort()

      assert staged_files == Enum.sort(files)

      for file <- files do
        {source, 0} = System.cmd("git", ["show", "#{revision}:#{package_path}/#{file}"])

        source =
          if gate == "publish" and file == "mix.exs",
            do: File.read!(Path.join(workspace, "#{package_path}/mix.exs")),
            else: source

        assert File.read!(Path.join(package_directory, file)) == source
      end

      script = """
      Mix.start()
      Code.compile_file("mix.exs")
      config = Backplane.AgentRuntime.MixProject.project()
      for app <- [:backplane_plugin_protocol, :backplane_mcp_protocol] do
        {^app, requirement} = List.keyfind(config[:deps], app, 0)
        true = is_binary(requirement)
      end
      false = Enum.any?([:build_path, :config_path, :deps_path, :lockfile], &Keyword.has_key?(config, &1))
      """

      {output, status} =
        System.cmd("elixir", ["-e", script], cd: package_directory, stderr_to_stdout: true)

      assert status == 0, output

      File.write!(Path.join(directory, "env"), "")

      {log, status} =
        System.cmd("bash", ["-e", "-o", "pipefail", "-c", stage["run"]],
          cd: workspace,
          env: [
            {"PACKAGE_NAME", "backplane_mcp_protocol"},
            {"PACKAGE_PATH", "apps/backplane_mcp_protocol"},
            {"GITHUB_WORKSPACE", workspace},
            {"GITHUB_ENV", Path.join(directory, "env")}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, log

      assert File.read!(Path.join(directory, "env")) ==
               "PACKAGE_DIRECTORY=#{workspace}/apps/backplane_mcp_protocol\n"
    end
  end

  test "normal release preserves version normalization while recovery keeps the committed manifest" do
    workspace = temporary_directory()
    package_path = "apps/backplane_agent_runtime"
    package_directory = Path.join(workspace, package_path)
    File.mkdir_p!(Path.join(package_directory, "lib"))
    manifest = Path.join(package_directory, "mix.exs")
    File.write!(manifest, "@version \"1.0.0\"\n")
    File.write!(Path.join(package_directory, "lib/source.ex"), "committed source\n")

    for args <- [
          ["init", "--quiet"],
          ["add", "."],
          [
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--quiet",
            "-m",
            "fixture"
          ]
        ] do
      {log, status} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
      assert status == 0, log
    end

    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    revision = String.trim(revision)
    File.write!(manifest, "@version \"1.0.1\"\n")
    File.write!(Path.join(package_directory, "lib/source.ex"), "uncommitted source\n")

    for {workflow, version} <- [{"release", "1.0.1"}, {"publish-hex", "1.0.0"}] do
      steps =
        YamlElixir.read_from_file!(".github/workflows/#{workflow}.yml")["jobs"]["hex-packages"][
          "steps"
        ]

      stage = Enum.find(steps, &(&1["name"] == "Select package working directory"))
      directory = temporary_directory()
      output = Path.join(directory, "env")

      {log, status} =
        System.cmd("bash", ["-e", "-o", "pipefail", "-c", stage["run"]],
          cd: workspace,
          env: [
            {"GATED_SHA", revision},
            {"PACKAGE_NAME", "backplane_agent_runtime"},
            {"PACKAGE_PATH", package_path},
            {"GITHUB_WORKSPACE", workspace},
            {"RUNNER_TEMP", directory},
            {"GITHUB_ENV", output}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, log
      "PACKAGE_DIRECTORY=" <> staged = File.read!(output)
      staged = String.trim(staged)
      assert File.read!(Path.join(staged, "mix.exs")) == "@version \"#{version}\"\n"
      assert File.read!(Path.join(staged, "lib/source.ex")) == "committed source\n"
    end
  end

  test "plugin version is readable by the existing release validator" do
    {version, 0} =
      System.cmd("awk", [
        "-F",
        ~s("),
        ~s(/^[[:space:]]*@version/ { print $2; exit }),
        "apps/backplane_plugin_protocol/mix.exs"
      ])

    assert String.trim(version) =~ ~r/^\d+\.\d+\.\d+/
  end

  test "plugin manifest supports standalone consumers and documentation without umbrella paths" do
    directory = temporary_directory()
    File.cp!("apps/backplane_plugin_protocol/mix.exs", Path.join(directory, "mix.exs"))

    script = """
    Mix.start()
    Code.compile_file("mix.exs")
    config = BackplanePluginProtocol.MixProject.project()
    true = config[:app] == :backplane_plugin_protocol
    true = is_binary(config[:version])
    true = config[:docs][:main] == "readme"
    true = "README.md" in config[:docs][:extras]
    false = Enum.any?([:build_path, :config_path, :deps_path, :lockfile], &Keyword.has_key?(config, &1))
    true = {:yaml_elixir, "~> 2.9"} in config[:deps]
    {:ex_doc, _, options} = List.keyfind(config[:deps], :ex_doc, 0)
    true = :dev in List.wrap(options[:only])
    false = options[:runtime]
    """

    {output, status} = System.cmd("elixir", ["-e", script], cd: directory, stderr_to_stdout: true)
    assert status == 0, output
  end

  defp temporary_directory do
    directory =
      Path.join(System.tmp_dir!(), "backplane-hex-release-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end
end
