defmodule Backplane.HostAgent.ChecksumTest do
  use ExUnit.Case, async: true

  alias Backplane.HostAgent.Checksum

  @tag :tmp_dir
  test "verify_file returns ok for correct sha256 checksum", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file.bin")
    File.write!(path, "abc")

    assert :ok =
             Checksum.verify_file(
               path,
               "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
             )
  end

  @tag :tmp_dir
  test "verify_file returns checksum mismatch for wrong sha256 checksum", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file.bin")
    File.write!(path, "abc")

    assert {:error, :checksum_mismatch} =
             Checksum.verify_file(path, "sha256:" <> String.duplicate("0", 64))
  end

  @tag :tmp_dir
  test "verify_file returns unsupported checksum for unsupported format", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "file.bin")
    File.write!(path, "abc")

    assert {:error, :unsupported_checksum} =
             Checksum.verify_file(path, "md5:900150983cd24fb0d6963f7d28e17f72")
  end

  @tag :tmp_dir
  test "verify_file returns missing file instead of raising", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing.bin")

    assert {:error, :missing_file} =
             Checksum.verify_file(missing, "sha256:" <> String.duplicate("0", 64))
  end
end
