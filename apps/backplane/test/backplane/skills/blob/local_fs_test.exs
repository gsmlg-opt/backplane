defmodule Backplane.Skills.Blob.LocalFSTest do
  use Backplane.DataCase, async: false

  alias Backplane.Settings
  alias Backplane.Skills.Blob.LocalFS

  @hash String.duplicate("a", 64)

  setup %{tmp_dir: tmp_dir} do
    :ok = Settings.set("skills.blob.local_root", tmp_dir)

    on_exit(fn ->
      if Process.whereis(Settings), do: Settings.set("skills.blob.local_root", nil)
    end)

    :ok
  end

  @tag :tmp_dir
  test "put/2 stores bytes under the configured root", %{tmp_dir: tmp_dir} do
    assert :ok = LocalFS.put(@hash, ["archive", "-bytes"])

    path = Path.join([tmp_dir, "sha256", "#{@hash}.tar.gz"])
    assert File.read!(path) == "archive-bytes"
  end

  @tag :tmp_dir
  test "get/1 returns a stream for existing archives" do
    :ok = LocalFS.put(@hash, ["content"])

    assert {:ok, stream} = LocalFS.get(@hash)
    assert Enum.join(stream) == "content"
  end

  @tag :tmp_dir
  test "exists?/1 returns true only for present blobs" do
    refute LocalFS.exists?(@hash)

    :ok = LocalFS.put(@hash, ["content"])

    assert LocalFS.exists?(@hash)
    refute LocalFS.exists?(String.duplicate("b", 64))
  end

  @tag :tmp_dir
  test "delete/1 removes an archive without failing when absent" do
    :ok = LocalFS.put(@hash, ["content"])

    assert :ok = LocalFS.delete(@hash)
    refute LocalFS.exists?(@hash)
    assert :ok = LocalFS.delete(@hash)
  end

  @tag :tmp_dir
  test "rejects malformed hashes" do
    assert {:error, :invalid_hash} = LocalFS.put("../bad", ["content"])
    assert {:error, :invalid_hash} = LocalFS.get("../bad")
    refute LocalFS.exists?("../bad")
    assert {:error, :invalid_hash} = LocalFS.delete("../bad")
  end
end
