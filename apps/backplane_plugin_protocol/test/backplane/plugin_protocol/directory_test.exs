defmodule Backplane.PluginProtocol.DirectoryTest do
  use ExUnit.Case, async: true

  alias Backplane.PluginProtocol
  alias Backplane.PluginProtocol.Archive

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    root = Path.join(directory, "plugin")
    File.mkdir!(root)
    File.write!(Path.join(root, "plugin.json"), manifest())
    write_skill(root, "good")
    %{root: root, outside: directory}
  end

  test "directory loading preserves each unknown manifest field warning", %{root: root} do
    manifest =
      manifest() |> JSON.decode!() |> Map.merge(%{"first-unknown" => 1, "second-unknown" => 2})

    File.write!(Path.join(root, "plugin.json"), JSON.encode!(manifest))

    assert {:ok, %{diagnostics: diagnostics}} = PluginProtocol.load_directory(root)
    assert Enum.count(diagnostics, &(&1.code == :unknown_manifest_field)) == 2
  end

  test "an escaping manifest rejects the plugin", %{root: root, outside: outside} do
    target = Path.join(outside, "manifest.json")
    File.write!(target, manifest())
    File.rm!(Path.join(root, "plugin.json"))
    File.ln_s!(target, Path.join(root, "plugin.json"))

    assert {:error, [%{code: :invalid_manifest_location}]} = PluginProtocol.load_directory(root)
  end

  test "an escaping skill and resource leave valid sibling skills available", %{
    root: root,
    outside: outside
  } do
    File.mkdir_p!(Path.join(root, "skills/bad"))
    target = Path.join(outside, "SKILL.md")
    File.write!(target, skill("bad"))
    File.ln_s!(target, Path.join(root, "skills/bad/SKILL.md"))
    File.ln_s!(target, Path.join(root, "skills/good/private.txt"))

    assert {:ok, package} = PluginProtocol.load_directory(root)
    assert [%{name: "good"}] = package.skills
    refute Map.has_key?(package.files, "skills/bad/SKILL.md")
    refute Map.has_key?(package.files, "skills/good/private.txt")
    assert Enum.any?(package.diagnostics, &(&1.code == :invalid_skill))
    assert Enum.any?(package.diagnostics, &(&1.code == :unsafe_package_path))
    assert {:error, {:unsafe_file_type, _}} = Archive.read_directory(root)
  end

  test "an escaping MCP location disables only MCP", %{root: root, outside: outside} do
    target = Path.join(outside, "mcp.json")
    File.write!(target, mcp())
    File.ln_s!(target, Path.join(root, "mcp.json"))

    assert {:ok, %{skills: [%{name: "good"}], mcp_servers: servers, diagnostics: diagnostics}} =
             PluginProtocol.load_directory(root)

    assert servers == %{}
    assert Enum.any?(diagnostics, &(&1.code == :invalid_mcp_location))
  end

  test "an escaping skills directory leaves MCP available", %{root: root, outside: outside} do
    File.rename!(Path.join(root, "skills"), Path.join(outside, "external-skills"))
    File.ln_s!("../external-skills", Path.join(root, "skills"))
    File.write!(Path.join(root, "mcp.json"), mcp())

    assert {:ok, %{skills: [], mcp_servers: %{"server" => _}, diagnostics: diagnostics}} =
             PluginProtocol.load_directory(root)

    assert Enum.any?(diagnostics, &(&1.code == :invalid_skills_location))
  end

  test "safe links resolve manifest, skill and resource bytes under their alias paths", %{
    root: root
  } do
    File.rename!(Path.join(root, "plugin.json"), Path.join(root, "manifest.json"))
    File.ln_s!("manifest.json", Path.join(root, "plugin.json"))

    File.rename!(
      Path.join(root, "skills/good/SKILL.md"),
      Path.join(root, "skills/good/source.md")
    )

    File.ln_s!("source.md", Path.join(root, "skills/good/SKILL.md"))
    File.mkdir!(Path.join(root, "assets"))
    File.write!(Path.join(root, "assets/data.txt"), "resource")
    File.ln_s!("../../assets", Path.join(root, "skills/good/resources"))

    assert {:ok, %{skills: [%{name: "good", files: resources}], diagnostics: [], files: files}} =
             PluginProtocol.load_directory(root)

    assert files["plugin.json"] == manifest()
    assert files["skills/good/SKILL.md"] == skill("good")
    assert resources["skills/good/resources/data.txt"] == "resource"
    assert {:error, {:unsafe_file_type, _}} = Archive.read_directory(root)
  end

  test "directory and symlink cycles are denied without losing valid components", %{root: root} do
    File.ln_s!(".", Path.join(root, "cycle"))
    File.ln_s!("loop-b", Path.join(root, "loop-a"))
    File.ln_s!("loop-a", Path.join(root, "loop-b"))

    assert {:ok, %{skills: [%{name: "good"}], diagnostics: diagnostics}} =
             PluginProtocol.load_directory(root)

    assert Enum.count(diagnostics, &(&1.code == :unsafe_package_path)) == 3
  end

  test "symlink targets resolve dot-dot after symlink expansion", %{root: root} do
    File.mkdir_p!(Path.join(root, "assets/nested"))
    File.write!(Path.join(root, "assets/value.txt"), "correct")
    File.write!(Path.join(root, "value.txt"), "incorrect")
    File.ln_s!("assets/nested", Path.join(root, "redirect"))
    File.ln_s!("redirect/../value.txt", Path.join(root, "alias.txt"))

    assert {:ok, %{files: files}} = PluginProtocol.load_directory(root)
    assert files["alias.txt"] == "correct"
  end

  defp write_skill(root, name) do
    File.mkdir_p!(Path.join(root, "skills/" <> name))
    File.write!(Path.join(root, "skills/" <> name <> "/SKILL.md"), skill(name))
  end

  defp skill(name), do: "---\nname: #{name}\ndescription: Example.\n---\nInstructions"

  defp manifest do
    JSON.encode!(%{
      "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
      "name" => "example"
    })
  end

  defp mcp do
    JSON.encode!(%{
      "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
      "mcpServers" => %{"server" => %{"type" => "stdio", "command" => "node"}}
    })
  end
end
