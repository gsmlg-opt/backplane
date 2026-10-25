defmodule Backplane.AgentRuntime.CodexViewImageContainmentTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.{PathGuard, Tools}
  alias Backplane.AgentRuntime.Error

  @moduletag :tmp_dir
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
       )

  setup %{tmp_dir: base} do
    root = Path.join(base, "workspace")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "control.png"), @png)
    File.write!(Path.join(outside, "outside.png"), @png)
    {:ok, root: root, outside: outside}
  end

  test "native image reads reject the reported absolute link chain", %{
    root: root,
    outside: outside
  } do
    File.ln_s!(outside, Path.join(root, "direct"))
    File.ln_s!(outside, Path.join(root, "b"))
    File.ln_s!(Path.join(root, "b"), Path.join(root, "a"))

    assert_image(root, "control.png")
    assert_forbidden(root, "direct/outside.png")
    assert_forbidden(root, "a/outside.png")
    assert_forbidden(root, Path.join(root, "a/outside.png"))
  end

  test "native image reads reject relative outward link chains", %{root: root} do
    File.ln_s!("../outside", Path.join(root, "relative-b"))
    File.ln_s!("relative-b", Path.join(root, "relative-a"))

    assert_forbidden(root, "relative-a/outside.png")
  end

  test "native image reads resolve linked ancestors inside substituted targets", %{
    root: root,
    outside: outside
  } do
    File.mkdir_p!(Path.join(outside, "images"))
    File.write!(Path.join(outside, "images/outside.png"), @png)
    File.ln_s!(outside, Path.join(root, "ancestor"))
    File.ln_s!(Path.join(root, "ancestor/images"), Path.join(root, "absolute-target"))
    File.ln_s!("ancestor/images", Path.join(root, "relative-target"))

    assert_forbidden(root, "absolute-target/outside.png")
    assert_forbidden(root, "relative-target/outside.png")
  end

  test "confined absolute and relative chains preserve native image results", %{root: root} do
    File.mkdir_p!(Path.join(root, "images"))
    File.write!(Path.join(root, "images/inside.png"), @png)
    File.ln_s!("images", Path.join(root, "relative-b"))
    File.ln_s!("relative-b", Path.join(root, "relative-a"))
    File.ln_s!(Path.join(root, "images"), Path.join(root, "absolute-b"))
    File.ln_s!(Path.join(root, "absolute-b"), Path.join(root, "absolute-a"))
    File.ln_s!(Path.join(root, "relative-b"), Path.join(root, "mixed"))

    for path <- [
          "control.png",
          "relative-a/inside.png",
          "absolute-a/inside.png",
          "mixed/inside.png"
        ] do
      assert_image(root, path)
    end

    assert_image(root, Path.join(root, "control.png"), "control.png")
  end

  test "a linked workspace root preserves controls and rejects outward chains", %{
    root: root,
    outside: outside,
    tmp_dir: base
  } do
    linked_root = Path.join(base, "workspace-link")
    File.ln_s!(root, linked_root)
    File.ln_s!(outside, Path.join(root, "b"))
    File.ln_s!("b", Path.join(root, "a"))

    assert_image(linked_root, "control.png")
    assert_forbidden(linked_root, "a/outside.png")
  end

  test "native image reads reject cyclic link resolution", %{root: root} do
    File.ln_s!("cycle-b", Path.join(root, "cycle-a"))
    File.ln_s!("cycle-a", Path.join(root, "cycle-b"))

    assert_resolution_limit(root, "cycle-a/control.png")
  end

  test "native image reads reject link chains exceeding the traversal bound", %{root: root} do
    Enum.each(0..39, fn index ->
      target = if index == 39, do: "control.png", else: "deep-#{index + 1}"
      File.ln_s!(target, Path.join(root, "deep-#{index}"))
    end)

    assert_resolution_limit(root, "deep-0")
    assert_image(root, "control.png")
  end

  defp assert_image(root, path, expected_path \\ nil) do
    assert {:ok, _authorized} = PathGuard.authorize(root, path)
    assert {:ok, result} = Tools.call(%{workspace: root}, "view_image", %{"path" => path})
    assert result.path == (expected_path || path)
    assert result.mime_type == "image/png"
    assert result.detail == "high"
    assert result.data == @png
    assert result.bytes == byte_size(@png)
    assert result.image_url == "data:image/png;base64,#{Base.encode64(@png)}"
  end

  defp assert_forbidden(root, path) do
    assert {:error, %Error{class: :forbidden}} = PathGuard.authorize(root, path)

    assert {:error, %Error{class: :forbidden}} =
             Tools.call(%{workspace: root}, "view_image", %{"path" => path})
  end

  defp assert_resolution_limit(root, path) do
    assert {:error, %Error{class: :resource_conflict, cause: :symlink_resolution_limit}} =
             PathGuard.authorize(root, path)

    assert {:error, %Error{class: :resource_conflict, cause: :symlink_resolution_limit}} =
             Tools.call(%{workspace: root}, "view_image", %{"path" => path})
  end
end
