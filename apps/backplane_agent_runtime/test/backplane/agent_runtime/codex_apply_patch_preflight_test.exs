defmodule Backplane.AgentRuntime.CodexApplyPatchPreflightTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.ApplyPatch
  alias Backplane.AgentRuntime.Error

  @moduletag :tmp_dir

  test "reports every ordered operation and both move paths without touching files", %{
    tmp_dir: root
  } do
    File.write!(Path.join(root, "source.txt"), "before\n")

    patch = """
    *** Begin Patch
    *** Add File: first.txt
    +one
    *** Delete File: deleted.txt
    *** Update File: source.txt
    @@
    -before
    +after
    *** Update File: source.txt
    *** Move to: nested/updated.txt
    @@
    -after
    +moved
    *** Move to: nested/legacy.txt
    legacy.txt
    *** End Patch
    """

    assert {:ok, %{root: ^root, patch_sha256: digest, operations: operations}} =
             ApplyPatch.preflight(root, patch)

    assert digest == Base.encode16(:crypto.hash(:sha256, patch), case: :lower)

    assert operations == [
             %{kind: :add, path: Path.join(root, "first.txt")},
             %{kind: :delete, path: Path.join(root, "deleted.txt")},
             %{kind: :update, path: Path.join(root, "source.txt"), destination: nil},
             %{
               kind: :update,
               path: Path.join(root, "source.txt"),
               destination: Path.join(root, "nested/updated.txt")
             },
             %{
               kind: :move,
               path: Path.join(root, "legacy.txt"),
               destination: Path.join(root, "nested/legacy.txt")
             }
           ]

    assert File.ls!(root) == ["source.txt"]
    assert File.read!(Path.join(root, "source.txt")) == "before\n"
  end

  test "duplicate relative and absolute targets preserve exact operation order", %{tmp_dir: root} do
    target = Path.join(root, "same.txt")

    patch = """
    *** Begin Patch
    *** Add File: same.txt
    +first
    *** Add File: #{target}
    +second
    *** Delete File: same.txt
    *** End Patch
    """

    assert {:ok, %{operations: operations}} = ApplyPatch.preflight(root, patch)

    assert operations == [
             %{kind: :add, path: target},
             %{kind: :add, path: target},
             %{kind: :delete, path: target}
           ]

    assert File.ls!(root) == []
  end

  test "a forbidden later operation is found before any earlier effect", %{tmp_dir: root} do
    patch =
      "*** Begin Patch\n*** Add File: first.txt\n+safe\n*** Add File: ../forbidden.txt\n+bad\n*** End Patch\n"

    assert {:error, %Error{class: :forbidden}} = ApplyPatch.preflight(root, patch)
    assert File.ls!(root) == []
  end

  test "every source and destination is confined", %{tmp_dir: root} do
    for body <- [
          "*** Delete File: ../outside.txt",
          "*** Update File: ../outside.txt\n@@\n-before\n+after",
          "*** Update File: source.txt\n*** Move to: ../outside.txt",
          "*** Move to: target.txt\n../outside.txt",
          "*** Move to: ../outside.txt\nsource.txt"
        ] do
      patch = "*** Begin Patch\n#{body}\n*** End Patch\n"
      assert {:error, %Error{class: :forbidden}} = ApplyPatch.preflight(root, patch)
      assert File.ls!(root) == []
    end
  end

  test "preflight shares execution's malformed input rejection", %{tmp_dir: root} do
    for patch <- [
          "not a patch",
          "*** Begin Patch\n*** Add File: empty.txt\n*** End Patch\n",
          "*** Begin Patch\n*** Update File: x\n@@\n?invalid\n*** End Patch\n",
          "*** Begin Patch\n*** Move to: target\none\ntwo\n*** End Patch\n"
        ] do
      assert {:error, %Error{class: :validation}} = ApplyPatch.preflight(root, patch)
      assert {:error, %Error{class: :validation}} = ApplyPatch.apply(root, patch)
      assert File.ls!(root) == []
    end

    assert {:error, %Error{class: :validation}} = ApplyPatch.preflight(root, nil)
  end

  test "preflight rejects unsafe linked write targets without changing them", %{tmp_dir: base} do
    root = Path.join(base, "workspace")
    outside = Path.join(base, "outside.txt")
    File.mkdir!(root)
    File.write!(outside, "original\n")
    File.ln!(outside, Path.join(root, "hardlink.txt"))
    File.ln_s!(outside, Path.join(root, "symlink.txt"))

    for path <- ["hardlink.txt", "symlink.txt"] do
      patch = "*** Begin Patch\n*** Add File: #{path}\n+changed\n*** End Patch\n"
      assert {:error, %Error{class: :forbidden}} = ApplyPatch.preflight(root, patch)
      assert File.read!(outside) == "original\n"
    end
  end

  test "preflight does not promise transactional execution or a future filesystem snapshot", %{
    tmp_dir: root
  } do
    patch =
      "*** Begin Patch\n*** Add File: first.txt\n+done\n*** Update File: missing.txt\n@@\n-before\n+after\n*** End Patch\n"

    assert {:ok, _} = ApplyPatch.preflight(root, patch)
    assert File.ls!(root) == []

    assert {:error, %Error{details: %{files: [%{action: :added, path: path}]}}} =
             ApplyPatch.apply(root, patch)

    assert path == Path.join(root, "first.txt")
    assert File.read!(path) == "done\n"
  end
end
