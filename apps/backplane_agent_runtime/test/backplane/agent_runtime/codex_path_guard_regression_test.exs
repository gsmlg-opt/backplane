defmodule Backplane.AgentRuntime.CodexPathGuardRegressionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.{ApplyPatch, PathGuard}
  alias Backplane.AgentRuntime.Error

  @moduletag :tmp_dir

  setup %{tmp_dir: base} do
    root = Path.join(base, "workspace")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    {:ok, root: root, outside: outside}
  end

  test "dangling and existing outward links are rejected before writes", %{
    root: root,
    outside: outside
  } do
    for {name, existing?} <- [{"dangling", false}, {"existing", true}] do
      target = Path.join(outside, name)
      if existing?, do: File.write!(target, "original\n")
      File.ln_s!(target, Path.join(root, name))

      assert {:error, %Error{class: :forbidden}} = PathGuard.authorize(root, name)

      assert {:error, %Error{class: :forbidden, details: %{files: []}}} =
               ApplyPatch.apply(root, add(name, "forbidden"))

      if existing? do
        assert File.read!(target) == "original\n"
      else
        refute File.exists?(target)
      end
    end
  end

  test "linked ancestors and symlinks inside link targets are resolved", %{
    root: root,
    outside: outside
  } do
    File.ln_s!(outside, Path.join(root, "ancestor"))
    File.ln_s!(Path.join(root, "ancestor/target"), Path.join(root, "nested-link"))

    for path <- ["ancestor/missing/sub/file", "nested-link"] do
      assert {:error, %Error{class: :forbidden}} = PathGuard.authorize(root, path)
      assert {:error, %Error{class: :forbidden}} = ApplyPatch.apply(root, add(path, "bad"))
    end

    assert File.ls!(outside) == []
  end

  test "link targets resolve parent components after traversing their symlinks", %{
    root: root,
    outside: outside
  } do
    File.mkdir_p!(Path.join(outside, "child"))
    File.ln_s!(Path.join(outside, "child"), Path.join(root, "bridge"))
    File.ln_s!("bridge/../escaped.txt", Path.join(root, "link"))

    assert {:error, %Error{class: :forbidden}} = PathGuard.authorize(root, "link")
    assert {:error, %Error{class: :forbidden}} = ApplyPatch.apply(root, add("link", "bad"))
    refute File.exists?(Path.join(outside, "escaped.txt"))
  end

  test "multiply linked add and update targets cannot overwrite another inode owner", %{
    root: root,
    outside: outside
  } do
    target = Path.join(outside, "shared.txt")
    File.write!(target, "original\n")
    File.ln!(target, Path.join(root, "shared.txt"))

    assert {:ok, _} = PathGuard.authorize(root, "shared.txt")
    assert {:error, %Error{class: :forbidden}} = PathGuard.authorize_write(root, "shared.txt")

    for patch <- [
          add("shared.txt", "changed"),
          "*** Begin Patch\n*** Update File: shared.txt\n@@\n-original\n+changed\n*** End Patch\n"
        ] do
      assert {:error, %Error{class: :forbidden, details: %{files: []}}} =
               ApplyPatch.apply(root, patch)

      assert File.read!(target) == "original\n"
      assert File.read!(Path.join(root, "shared.txt")) == "original\n"
    end
  end

  test "both move forms reject a multiply linked destination before changing the source", %{
    root: root,
    outside: outside
  } do
    shared = Path.join(outside, "shared.txt")
    source = Path.join(root, "source.txt")
    File.write!(shared, "outside\n")
    File.write!(source, "original\n")
    File.ln!(shared, Path.join(root, "destination.txt"))

    for patch <- [
          "*** Begin Patch\n*** Move to: destination.txt\nsource.txt\n*** End Patch\n",
          "*** Begin Patch\n*** Update File: source.txt\n*** Move to: destination.txt\n@@\n-original\n+changed\n*** End Patch\n"
        ] do
      assert {:error, %Error{class: :forbidden, details: %{files: []}}} =
               ApplyPatch.apply(root, patch)

      assert File.read!(shared) == "outside\n"
      assert File.read!(source) == "original\n"
    end
  end

  test "inward links and ordinary missing intermediate paths remain writable", %{root: root} do
    File.mkdir_p!(Path.join(root, "data"))
    File.ln_s!("data/new.txt", Path.join(root, "inward.txt"))

    assert {:ok, _} = ApplyPatch.apply(root, add("inward.txt", "inside"))
    assert File.read!(Path.join(root, "data/new.txt")) == "inside\n"
    assert {:ok, _} = ApplyPatch.apply(root, add("missing/sub/new.txt", "nested"))
    assert File.read!(Path.join(root, "missing/sub/new.txt")) == "nested\n"
  end

  test "delete and move preserve inward symlink entry semantics", %{root: root} do
    target = Path.join(root, "original.txt")
    File.write!(target, "original")
    link = Path.join(root, "entry.txt")
    File.ln_s!("original.txt", link)

    assert {:ok, _} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Delete File: entry.txt\n*** End Patch\n"
             )

    assert File.read!(target) == "original"
    assert {:error, :enoent} = File.lstat(link)
    File.ln_s!("original.txt", link)

    assert {:ok, _} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Move to: moved.txt\nentry.txt\n*** End Patch\n"
             )

    assert File.read!(target) == "original"
    assert {:ok, "original.txt"} = File.read_link(Path.join(root, "moved.txt"))
  end

  test "a symlink root resolves to its physical workspace", %{root: root, tmp_dir: base} do
    alias_root = Path.join(base, "workspace-link")
    File.ln_s!(root, alias_root)
    assert {:ok, path} = PathGuard.authorize(alias_root, "new.txt")
    assert path == Path.join(root, "new.txt")
    assert {:ok, _} = ApplyPatch.apply(alias_root, add("new.txt", "inside"))
    assert File.read!(Path.join(root, "new.txt")) == "inside\n"
  end

  test "resolution loops and malformed paths return native errors", %{root: root} do
    File.ln_s!("loop-b", Path.join(root, "loop-a"))
    File.ln_s!("loop-a", Path.join(root, "loop-b"))
    assert {:error, %Error{class: :resource_conflict}} = PathGuard.authorize(root, "loop-a")
    assert {:error, %Error{class: :validation}} = PathGuard.authorize(root, "bad" <> <<0>>)
    assert {:error, %Error{class: :validation}} = PathGuard.authorize(root <> <<0>>, "file")
  end

  defp add(path, contents),
    do: "*** Begin Patch\n*** Add File: #{path}\n+#{contents}\n*** End Patch\n"
end
