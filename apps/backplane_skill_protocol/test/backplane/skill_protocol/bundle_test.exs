defmodule Backplane.SkillProtocol.BundleTest do
  use ExUnit.Case, async: true

  import Backplane.SkillProtocol.ArchiveHelpers

  alias Backplane.SkillProtocol.{Bundle, Error, Resource, SkillRef}

  @moduletag :tmp_dir

  test "complete bundle inventories and prepares every resource without executing scripts", %{
    tmp_dir: tmp_dir
  } do
    marker = Path.join(tmp_dir, "executed")
    script = "#!/bin/sh\ntouch #{marker}\n"
    binary = <<0, 1, 2, 255>>

    archive =
      archive!(tmp_dir, [
        {"example-skill/SKILL.md", skill_md()},
        {"example-skill/references/guide.md", "Guide"},
        {"example-skill/assets/image.bin", binary},
        {"example-skill/scripts/run.sh", script},
        {"example-skill/examples/nested/SKILL.md", "ordinary resource"}
      ])

    reference = %SkillRef{source_id: "fixture", skill_id: "skill/opaque", revision: "r1"}

    assert {:ok, bundle} = Bundle.inspect(archive, ref: reference)
    assert bundle.manifest.entrypoint == "SKILL.md"
    assert bundle.manifest.artifact_digest == Bundle.artifact_digest(File.read!(archive))

    assert Enum.map(bundle.manifest.files, & &1.path) == [
             "SKILL.md",
             "assets/image.bin",
             "examples/nested/SKILL.md",
             "references/guide.md",
             "scripts/run.sh"
           ]

    assert bundle.manifest.ref.artifact_digest == bundle.manifest.artifact_digest

    destination = Path.join(tmp_dir, "prepared")
    assert {:ok, prepared} = Bundle.prepare(bundle, destination)
    assert {:ok, "Guide"} = Resource.read(prepared, "references/guide.md")
    assert {:ok, ^binary} = Resource.read(prepared, "assets/image.bin")
    assert {:ok, ^script} = Resource.read(prepared, "scripts/run.sh")
    refute File.exists?(marker)
  end

  test "rejects unsafe names, symlinks, duplicate targets, collisions, and expansion limits", %{
    tmp_dir: tmp_dir
  } do
    for {name, bad_path} <- [
          {"traversal.tar.gz", "example-skill/../outside"},
          {"absolute.tar.gz", "/example-skill/outside"},
          {"drive.tar.gz", "example-skill/C:/outside"},
          {"backslash.tar.gz", "example-skill\\outside"}
        ] do
      archive =
        archive!(tmp_dir, [{"example-skill/SKILL.md", skill_md()}, {bad_path, "bad"}], name)

      assert {:error, %Error{code: :invalid_bundle}} = Bundle.inspect(archive)
    end

    assert {:error, %Error{code: :invalid_bundle}} = Bundle.inspect(symlink_archive!(tmp_dir))

    duplicate =
      archive!(
        tmp_dir,
        [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/a", "1"},
          {"example-skill/a", "2"}
        ],
        "duplicate.tar.gz"
      )

    assert {:error, %Error{code: :invalid_bundle}} = Bundle.inspect(duplicate)

    collision =
      archive!(
        tmp_dir,
        [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/A", "1"},
          {"example-skill/a", "2"}
        ],
        "collision.tar.gz"
      )

    assert {:error, %Error{code: :invalid_bundle}} = Bundle.inspect(collision)

    bomb =
      archive!(
        tmp_dir,
        [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/large", String.duplicate("x", 4096)}
        ],
        "bomb.tar.gz"
      )

    assert {:error, %Error{code: :limit_exceeded}} =
             Bundle.inspect(bomb, max_expanded_bytes: 1024)
  end

  test "rejects hardlinks and character devices without materializing archive content", %{
    tmp_dir: tmp_dir
  } do
    outside = Path.join(tmp_dir, "outside")
    File.write!(outside, "sentinel")

    for {archive, type} <- [
          {hardlink_archive!(tmp_dir), :link},
          {character_device_archive!(tmp_dir), :char}
        ] do
      assert {:error,
              %Error{
                code: :invalid_bundle,
                message: "archive entry type is unsupported",
                context: %{type: ^type}
              }} =
               Task.async(fn -> Bundle.inspect(archive) end)
               |> Task.await(1_000)

      assert File.read!(outside) == "sentinel"
      refute File.exists?(outside <> ".materialized")
    end
  end

  test "bad declared inventory, cancellation, and escaped resource access fail without publication",
       %{tmp_dir: tmp_dir} do
    archive =
      archive!(tmp_dir, [{"example-skill/SKILL.md", skill_md()}, {"example-skill/a", "A"}])

    assert {:error, %Error{code: :cancelled}} =
             Bundle.inspect(archive, cancelled?: fn -> true end)

    destination = Path.join(tmp_dir, "cancelled")

    assert {:error, %Error{code: :cancelled}} =
             Bundle.prepare(archive, destination, cancelled?: fn -> true end)

    refute File.exists?(destination)

    assert {:ok, prepared} = Bundle.prepare(archive, Path.join(tmp_dir, "prepared"))
    assert {:error, %Error{}} = Resource.read(prepared, "../outside")

    File.rm!(Path.join(prepared.root, "a"))
    File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(prepared.root, "a"))
    File.write!(Path.join(tmp_dir, "outside"), "outside")
    assert {:error, %Error{}} = Resource.read(prepared, "a")

    bad_manifest = %{
      prepared.manifest
      | files: [%{path: "missing", bytes: 1, sha256: String.duplicate("0", 64)}]
    }

    assert {:error, %Error{code: :not_found}} =
             Resource.read(%{prepared | manifest: bad_manifest}, "a")
  end

  test "resource reads canonicalize an aliased root without allowing symlink escape", %{
    tmp_dir: tmp_dir
  } do
    archive =
      archive!(tmp_dir, [
        {"example-skill/SKILL.md", skill_md()},
        {"example-skill/references/guide.md", "guide"}
      ])

    actual_root = Path.join(tmp_dir, "actual-root")
    alias_root = Path.join(tmp_dir, "alias-root")
    File.mkdir_p!(actual_root)
    File.ln_s!(actual_root, alias_root)

    assert {:ok, prepared} = Bundle.prepare(archive, Path.join(alias_root, "prepared"))
    assert {:ok, "guide"} = Resource.read(prepared, "references/guide.md")

    outside = Path.join(tmp_dir, "outside")
    resource = Path.join(prepared.root, "references/guide.md")
    File.write!(outside, "outside")
    File.rm!(resource)
    File.ln_s!(outside, resource)

    assert {:error, %Error{code: :invalid_request}} =
             Resource.read(prepared, "references/guide.md")
  end

  test "pack and inspect agree on exact complete resources", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "packed-skill")
    File.mkdir_p!(Path.join(root, "references"))
    File.write!(Path.join(root, "SKILL.md"), skill_md("packed-skill"))
    File.write!(Path.join(root, "references/info.md"), "info")
    archive = Path.join(tmp_dir, "packed.tar.gz")

    assert {:ok, bundle} = Bundle.pack(root, archive)
    assert Enum.map(bundle.manifest.files, & &1.path) == ["SKILL.md", "references/info.md"]
  end

  test "owned staging is private while populated and is removed after cancellation", %{
    tmp_dir: tmp_dir
  } do
    archive =
      archive!(tmp_dir, [
        {"example-skill/SKILL.md", skill_md()},
        {"example-skill/references/guide.md", "guide"}
      ])

    assert {:ok, bundle} = Bundle.inspect(archive)
    destination = Path.join(tmp_dir, "private-prepared")
    {:ok, checks} = Agent.start_link(fn -> 0 end)

    cancelled? = fn ->
      check = Agent.get_and_update(checks, &{&1, &1 + 1})

      if check == 2 do
        [stage] =
          Path.wildcard(Path.join(tmp_dir, ".private-prepared.stage.*"), match_dot: true)

        assert_private_permission(stage, 0o700)
        assert_private_permission(Path.join(stage, "SKILL.md"), 0o600)
        true
      else
        false
      end
    end

    assert {:error, %Error{code: :cancelled}} =
             Bundle.prepare(bundle, destination, cancelled?: cancelled?)

    assert Path.wildcard(Path.join(tmp_dir, ".private-prepared.stage.*"), match_dot: true) == []
    refute File.exists?(destination)
  end

  test "private permissions hold under a permissive subprocess umask", %{tmp_dir: tmp_dir} do
    if match?({:unix, _}, :os.type()) do
      archive =
        archive!(tmp_dir, [
          {"example-skill/SKILL.md", skill_md()},
          {"example-skill/references/guide.md", "guide"}
        ])

      package_root = Path.expand("../../..", __DIR__)
      destination = Path.join(tmp_dir, "subprocess-prepared")

      {output, 0} =
        System.cmd(
          "/bin/sh",
          [
            "-c",
            "umask 022; exec mix run --no-compile test/support/temporary_permissions_probe.exs"
          ],
          cd: package_root,
          env: [
            {"MIX_ENV", "test"},
            {"SKILL_PROTOCOL_PROBE_ARCHIVE", archive},
            {"SKILL_PROTOCOL_PROBE_DESTINATION", destination}
          ],
          stderr_to_stdout: true
        )

      assert String.trim(output) ==
               "source=700/600/clean inflate=700/600/clean prepare=700/600/clean"

      refute File.exists?(destination)
    else
      assert true
    end
  end

  defp permission(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end

  defp assert_private_permission(path, expected) do
    if match?({:unix, _}, :os.type()),
      do: assert(permission(path) == expected),
      else: assert(File.exists?(path))
  end
end
