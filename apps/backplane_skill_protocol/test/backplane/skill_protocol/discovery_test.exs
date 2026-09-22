defmodule Backplane.SkillProtocol.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.{Diagnostic, Error, Resolver, SkillRef}
  alias Backplane.SkillProtocol.Source.Local

  @moduletag :tmp_dir

  defp write_skill(root, directory, name) do
    path = Path.join([root, directory, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "---\nname: #{name}\ndescription: #{name}\n---\nBody")
  end

  test "discovery order and precedence are deterministic and equal ranks conflict", %{
    tmp_dir: tmp_dir
  } do
    one = Path.join(tmp_dir, "one")
    two = Path.join(tmp_dir, "two")
    write_skill(one, "alpha", "shared")
    write_skill(two, "beta", "shared")

    roots = [
      %{source_id: "two", path: two, precedence: 20},
      %{source_id: "one", path: one, precedence: 10}
    ]

    assert {:ok, [first, second]} = Local.discover(roots)
    assert {first.ref.source_id, second.ref.source_id} == {"one", "two"}
    assert {:ok, ^first} = Resolver.resolve([second, first], "shared")

    tied = [%{first | precedence: 10}, %{second | precedence: 10}]
    assert {:error, %Error{code: :ambiguous_skill}} = Resolver.resolve(tied, "shared")
  end

  test "a qualified reference never switches source", %{tmp_dir: tmp_dir} do
    one = Path.join(tmp_dir, "one")
    two = Path.join(tmp_dir, "two")
    write_skill(one, "same", "shared")
    write_skill(two, "same", "shared")

    assert {:ok, descriptors} =
             Local.discover([%{source_id: "one", path: one}, %{source_id: "two", path: two}])

    reference = %SkillRef{source_id: "two", skill_id: "same"}
    assert {:ok, descriptor} = Resolver.resolve(descriptors, reference)
    assert descriptor.ref.source_id == "two"

    assert {:error, %Error{code: :not_found}} =
             Resolver.resolve(descriptors, %{reference | source_id: "missing"})
  end

  test "linked paths cannot escape an approved root and cycles terminate", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    outside = Path.join(tmp_dir, "outside")
    write_skill(root, "inside", "inside")
    write_skill(outside, "escaped", "escaped")
    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:error, %Error{phase: :discovery}} =
             Local.discover([%{source_id: "local", path: root}])

    File.rm!(Path.join(root, "escape"))
    File.ln_s!(root, Path.join(root, "loop"))
    assert {:ok, [descriptor]} = Local.discover([%{source_id: "local", path: root}])
    assert descriptor.name == "inside"
  end

  test "a linked skill document cannot escape an approved root", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    outside = Path.join(tmp_dir, "outside")
    write_skill(root, "inside", "inside")
    write_skill(outside, "escaped", "escaped")
    linked_path = Path.join([root, "linked", "SKILL.md"])
    File.mkdir_p!(Path.dirname(linked_path))
    File.ln_s!(Path.join([outside, "escaped", "SKILL.md"]), linked_path)

    assert {:error, %Error{phase: :discovery}} =
             Local.discover_with_diagnostics([%{source_id: "local", path: root}])
  end

  test "scan depth and entry limits fail explicitly", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    write_skill(root, "a/b", "deep")

    assert {:error, %Error{code: :limit_exceeded}} =
             Local.discover([%{source_id: "local", path: root}], max_depth: 1)

    assert {:error, %Error{code: :limit_exceeded}} =
             Local.discover([%{source_id: "local", path: root}], max_entries: 1)
  end

  test "invalid local documents do not hide valid siblings", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    write_skill(root, "alpha", "alpha")
    invalid_path = Path.join([root, "broken", "SKILL.md"])
    File.mkdir_p!(Path.dirname(invalid_path))
    File.write!(invalid_path, "---\nname: [\n---\ninvalid document")

    assert {:ok, [descriptor]} = Local.discover([%{source_id: "local", path: root}])
    assert descriptor.name == "alpha"

    assert {:ok, [^descriptor], [%Diagnostic{} = diagnostic]} =
             Local.discover_with_diagnostics([%{source_id: "local", path: root}])

    assert diagnostic.code == :malformed_frontmatter
    assert diagnostic.phase == :discovery
    assert diagnostic.severity == :warning
    assert diagnostic.context == %{path: "broken/SKILL.md", code: :malformed_frontmatter}
    refute diagnostic.message =~ "invalid document"
  end

  test "local discovery diagnostics are deterministic and bounded", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")

    for directory <- ["zeta", "alpha", "middle"] do
      path = Path.join([root, directory, "SKILL.md"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not a skill document")
    end

    assert {:ok, [], diagnostics} =
             Local.discover_with_diagnostics([%{source_id: "local", path: root}],
               max_diagnostics: 2
             )

    assert Enum.map(diagnostics, & &1.context.path) == ["alpha/SKILL.md", "middle/SKILL.md"]
  end

  test "unreadable local documents are skipped when permissions are enforced", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    write_skill(root, "alpha", "alpha")
    unreadable_path = Path.join([root, "broken", "SKILL.md"])
    File.mkdir_p!(Path.dirname(unreadable_path))
    File.write!(unreadable_path, "---\nname: broken\ndescription: broken\n---\nBody")
    File.chmod!(unreadable_path, 0o000)

    try do
      case File.read(unreadable_path) do
        {:error, _reason} ->
          assert {:ok, [descriptor], [%Diagnostic{code: :invalid_document} = diagnostic]} =
                   Local.discover_with_diagnostics([%{source_id: "local", path: root}])

          assert descriptor.name == "alpha"
          assert diagnostic.context.path == "broken/SKILL.md"

        {:ok, _contents} ->
          assert {:ok, [_alpha, _broken], []} =
                   Local.discover_with_diagnostics([%{source_id: "local", path: root}])
      end
    after
      File.chmod!(unreadable_path, 0o644)
    end
  end

  test "invalid root configuration remains terminal", %{tmp_dir: tmp_dir} do
    assert {:error, %Error{code: :invalid_request}} =
             Local.discover_with_diagnostics([
               %{source_id: "local", path: Path.join(tmp_dir, "missing")}
             ])
  end
end
