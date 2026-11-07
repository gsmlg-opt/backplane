ExUnit.start()

defmodule Backplane.McpHexPackageTest do
  use ExUnit.Case, async: false

  @repository Path.expand("..", __DIR__)
  @package "apps/backplane_mcp_protocol"

  test "umbrella Hex package declares its required published schema dependency" do
    assert_schema_dependency(:umbrella)
  end

  test "standalone Hex package declares its required published schema dependency" do
    assert_schema_dependency(:standalone)
  end

  defp assert_schema_dependency(layout) do
    directory = package_fixture(layout)

    {output, status} =
      System.cmd("mix", ["hex.build"],
        cd: directory,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "dev"},
          {"MIX_BUILD_PATH", nil},
          {"MIX_DEPS_PATH", nil},
          {"MIX_EXS", nil},
          {"HEX_OFFLINE", "1"},
          {"ERL_FLAGS", "+S 2:2"}
        ]
      )

    assert status == 0, output
    [archive] = Path.wildcard(Path.join(directory, "backplane_mcp_protocol-*.tar"))

    assert {:ok, [{~c"metadata.config", contents}]} =
             :erl_tar.extract(String.to_charlist(archive), [
               :memory,
               {:files, [~c"metadata.config"]}
             ])

    metadata_path = Path.join(directory, "metadata.config")
    File.write!(metadata_path, contents)
    assert {:ok, terms} = :file.consult(String.to_charlist(metadata_path))
    metadata = Map.new(terms)

    assert metadata["name"] == "backplane_mcp_protocol"

    requirements = metadata |> Map.fetch!("requirements") |> Enum.map(&Map.new/1)
    [schema] = Enum.filter(requirements, &(&1["name"] == "backplane_schema"))

    assert schema["app"] == "backplane_schema"
    assert schema["optional"] == false
    assert schema["repository"] == "hexpm"
    assert {:ok, requirement} = Version.parse_requirement(schema["requirement"])
    assert Version.match?("1.10.58", requirement)
    assert Version.match?("1.10.59", requirement)
    refute Map.has_key?(schema, "path")
    refute Map.has_key?(schema, "in_umbrella")
  end

  defp package_fixture(layout) do
    root =
      Path.join(
        System.tmp_dir!(),
        "backplane-mcp-hex-#{layout}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    directory =
      case layout do
        :umbrella ->
          File.mkdir_p!(Path.join(root, "config"))
          File.write!(Path.join(root, "config/config.exs"), "import Config\n")
          Path.join(root, @package)

        :standalone ->
          Path.join(root, "standalone/backplane_mcp_protocol")
      end

    {files, 0} = System.cmd("git", ["ls-files", "-z", "--", @package], cd: @repository)

    for file <- String.split(files, "\0", trim: true) do
      destination = Path.join(directory, Path.relative_to(file, @package))
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join(@repository, file), destination)
    end

    assert File.dir?(Path.expand("../../apps", directory)) == (layout == :umbrella)
    directory
  end
end
