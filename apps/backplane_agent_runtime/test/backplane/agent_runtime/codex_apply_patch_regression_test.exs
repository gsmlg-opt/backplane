defmodule Backplane.AgentRuntime.CodexApplyPatchRegressionTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.ApplyPatch
  alias Backplane.AgentRuntime.Error

  @tag :tmp_dir
  test "rename applies edits and creates the destination directory", %{tmp_dir: root} do
    File.write!(Path.join(root, "old.txt"), "before\n")

    assert {:ok, %{files: [%{action: :moved, path: destination}]}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: old.txt\n*** Move to: sub/new.txt\n@@\n-before\n+after\n*** End Patch\n"
             )

    assert destination == Path.join(root, "sub/new.txt")
    assert File.read!(destination) == "after\n"
    refute File.exists?(Path.join(root, "old.txt"))
  end

  @tag :tmp_dir
  test "ordered nonadjacent hunks and explicit anchors change the intended occurrence", %{
    tmp_dir: root
  } do
    path = Path.join(root, "note.txt")
    File.write!(path, "top\nrepeated\nmiddle\nrepeated\nbottom\n")

    assert {:ok, %{files: [%{action: :updated}]}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: note.txt\n@@ top\n repeated\n+first\n@@ middle\n repeated\n+second\n*** End Patch\n"
             )

    assert File.read!(path) == "top\nrepeated\nfirst\nmiddle\nrepeated\nsecond\nbottom\n"
  end

  @tag :tmp_dir
  test "EOF marker constrains a hunk to the file end", %{tmp_dir: root} do
    path = Path.join(root, "note.txt")
    File.write!(path, "same\nother\nsame\n")

    assert {:ok, _} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: note.txt\n@@\n-same\n+last\n*** End of File\n*** End Patch\n"
             )

    assert File.read!(path) == "same\nother\nlast\n"

    assert {:error, %Error{class: :resource_conflict, details: %{files: []}}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: note.txt\n@@\n-same\n+wrong\n*** End of File\n*** End Patch\n"
             )

    assert File.read!(path) == "same\nother\nlast\n"
  end

  @tag :tmp_dir
  test "malformed patch lines are rejected before mutation", %{tmp_dir: root} do
    path = Path.join(root, "note.txt")
    File.write!(path, "before\n")

    for body <- [
          "oops",
          "?before",
          "*** End of File\n+wrong",
          "@@\n?wrong",
          "@@",
          "@@\n@@",
          "@@\n-before\n+after\n@@"
        ] do
      assert {:error, %Error{class: :validation}} =
               ApplyPatch.apply(
                 root,
                 "*** Begin Patch\n*** Update File: note.txt\n#{body}\n*** End Patch\n"
               )

      assert File.read!(path) == "before\n"
    end
  end

  @tag :tmp_dir
  test "path escape is rejected and earlier file mutations are reported on later failure", %{
    tmp_dir: root
  } do
    patch =
      "*** Begin Patch\n*** Add File: created.txt\n+created\n*** Update File: missing.txt\n@@\n-old\n+new\n*** End Patch\n"

    assert {:error, %Error{details: %{files: [%{action: :added, path: created}]}}} =
             ApplyPatch.apply(root, patch)

    assert created == Path.join(root, "created.txt")
    assert File.read!(created) == "created\n"

    assert {:error, %Error{class: :forbidden}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Add File: ../escape.txt\n+bad\n*** End Patch\n"
             )

    refute File.exists?(Path.expand("../escape.txt", root))
  end

  @tag :tmp_dir
  test "uncertain write reports prior successful mutations and the uncertain target", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "directory"))

    assert {:error,
            %Error{
              class: :unknown_outcome,
              details: %{files: [%{action: :added, path: first}], uncertain_files: [uncertain]}
            }} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Add File: first.txt\n+done\n*** Add File: directory\n+cannot write\n*** End Patch\n"
             )

    assert first == Path.join(root, "first.txt")
    assert uncertain == Path.join(root, "directory")
    assert File.read!(first) == "done\n"
  end

  @tag :tmp_dir
  test "failed destination directory creation does not invent a write", %{tmp_dir: root} do
    File.write!(Path.join(root, "source.txt"), "before\n")
    File.write!(Path.join(root, "blocked"), "a file\n")

    assert {:error, %Error{class: :resource_conflict, details: %{files: []}}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: source.txt\n*** Move to: blocked/new.txt\n@@\n-before\n+after\n*** End Patch\n"
             )

    assert File.read!(Path.join(root, "source.txt")) == "before\n"
    assert File.read!(Path.join(root, "blocked")) == "a file\n"
  end

  @tag :tmp_dir
  test "pinned matching seeks after the anchor, trims context, and prefers EOF", %{tmp_dir: root} do
    path = Path.join(root, "note.txt")
    File.write!(path, "anchor\n  target  \nrepeat\nrepeat\n")

    assert {:ok, _} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: note.txt\n@@ anchor\n-target\n+changed\n@@\n-repeat\n+last\n*** End of File\n*** End Patch\n"
             )

    assert File.read!(path) == "anchor\nchanged\nrepeat\nlast\n"
  end

  @tag :tmp_dir
  test "pinned add overwrites a file and pure insertion appends at EOF", %{tmp_dir: root} do
    path = Path.join(root, "note.txt")
    File.write!(path, "old\n")

    assert {:ok, %{files: [%{action: :added}]}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Add File: note.txt\n+new\n*** End Patch\n"
             )

    assert File.read!(path) == "new\n"

    assert {:ok, %{files: [%{action: :updated}]}} =
             ApplyPatch.apply(
               root,
               "*** Begin Patch\n*** Update File: note.txt\n@@\n+tail\n*** End of File\n*** End Patch\n"
             )

    assert File.read!(path) == "new\ntail\n"
  end
end
