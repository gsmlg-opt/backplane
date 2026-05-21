defmodule Backplane.Skills.Blob.LocalFSTest do
  use ExUnit.Case, async: true

  alias Backplane.Skills.Blob
  alias Backplane.Skills.Blob.LocalFS

  @moduletag :tmp_dir

  describe "put/2" do
    test "stores bytes under the sha256 content address", %{tmp_dir: tmp_dir} do
      bytes = "archive bytes"
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert {:ok, "sha256/" <> ^hash <> ".tar.gz"} = LocalFS.put(bytes, root: tmp_dir)
      assert File.read!(Path.join([tmp_dir, "sha256", "#{hash}.tar.gz"])) == bytes
    end

    test "facade delegates to local storage", %{tmp_dir: tmp_dir} do
      bytes = "facade archive bytes"
      hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

      assert {:ok, "sha256/" <> ^hash <> ".tar.gz"} = Blob.put(bytes, root: tmp_dir)
    end
  end

  describe "get/2" do
    test "returns a stream for existing archives", %{tmp_dir: tmp_dir} do
      bytes = "streamed archive bytes"
      assert {:ok, ref} = LocalFS.put(bytes, root: tmp_dir)

      assert {:ok, stream} = LocalFS.get(ref, root: tmp_dir)
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() == bytes
    end

    test "returns not_found for absent archives", %{tmp_dir: tmp_dir} do
      ref = "sha256/#{String.duplicate("0", 64)}.tar.gz"

      assert {:error, :not_found} = LocalFS.get(ref, root: tmp_dir)
    end
  end

  describe "exists?/2" do
    test "returns true only for present blobs", %{tmp_dir: tmp_dir} do
      bytes = "present archive bytes"
      assert {:ok, ref} = LocalFS.put(bytes, root: tmp_dir)

      assert LocalFS.exists?(ref, root: tmp_dir)
      refute LocalFS.exists?("sha256/#{String.duplicate("0", 64)}.tar.gz", root: tmp_dir)
    end
  end

  describe "delete/2" do
    test "removes an archive and is idempotent when absent", %{tmp_dir: tmp_dir} do
      assert {:ok, ref} = LocalFS.put("delete me", root: tmp_dir)
      assert LocalFS.exists?(ref, root: tmp_dir)

      assert :ok = LocalFS.delete(ref, root: tmp_dir)
      refute LocalFS.exists?(ref, root: tmp_dir)
      assert :ok = LocalFS.delete(ref, root: tmp_dir)
    end
  end

  describe "strict refs" do
    test "rejects non-canonical refs", %{tmp_dir: tmp_dir} do
      invalid_refs = [
        "../sha256/#{String.duplicate("0", 64)}.tar.gz",
        "sha256/#{String.duplicate("A", 64)}.tar.gz",
        "sha256/#{String.duplicate("0", 63)}.tar.gz",
        "sha256/#{String.duplicate("0", 64)}",
        "other/#{String.duplicate("0", 64)}.tar.gz"
      ]

      for ref <- invalid_refs do
        assert {:error, :not_found} = LocalFS.get(ref, root: tmp_dir)
        refute LocalFS.exists?(ref, root: tmp_dir)
        assert :ok = LocalFS.delete(ref, root: tmp_dir)
      end
    end
  end
end
