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

      assert Enum.map(jobs["hex-packages"]["strategy"]["matrix"]["package"], & &1["name"]) ==
               @packages

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
          env: [{"GITHUB_OUTPUT", output}],
          stderr_to_stdout: true
        )

      assert status == 0, log
      assert File.read!(output) == "present=#{present?}\n"
    end

    for step <- Enum.drop_while(steps, &(&1["id"] != "package")) |> tl() do
      assert step["if"] == "steps.package.outputs.present == 'true'"
    end

    verifier = workflow["jobs"]["qualify"]["steps"] |> Enum.find(&(&1["id"] == "gate"))
    assert verifier["run"] =~ "python3 scripts/verify_qualified_hex_publication.py"
    refute Enum.any?(steps, &(&1["run"] && &1["run"] =~ "set-version.sh"))
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
