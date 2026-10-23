defmodule Backplane.PluginProtocol.ArchiveTest do
  use ExUnit.Case, async: true
  alias Backplane.PluginProtocol.Archive

  test "snapshot is deterministic, binary-preserving and handles USTAR prefixes" do
    files = %{
      "plugin.json" => "{}",
      "skills/a/assets/blob" => <<0, 255>>,
      (String.duplicate("long/", 25) <> "resource") => "resource"
    }

    assert {:ok, first} = Archive.pack(files)
    assert {:ok, ^first} = Archive.pack(files |> Enum.reverse() |> Map.new())
    assert {:ok, ^files} = Archive.unpack(first)
    assert Archive.digest(first) =~ ~r/\A[a-f0-9]{64}\z/
  end

  test "executable modes round-trip without privileged permission bits" do
    files = %{"bin/server" => "#!/bin/sh\nexit 0", "plugin.json" => "{}"}
    assert {:ok, archive} = Archive.pack(files, modes: %{"bin/server" => 0o755})

    assert {:ok, %{files: ^files, modes: %{"bin/server" => 0o755, "plugin.json" => 0o644}}} =
             Archive.unpack_with_metadata(archive)

    assert {:error, :invalid_modes} = Archive.pack(files, modes: %{"bin/server" => 0o4755})
    assert {:error, :invalid_modes} = Archive.pack(files, modes: %{"missing" => 0o755})
  end

  test "rejects path traversal, absolute paths, windows paths, file conflicts and non-byte entries" do
    for path <- [
          "../secret",
          "/secret",
          "a/../../b",
          "a\\..\\b",
          "C:/x",
          "./plugin.json",
          "a//b",
          "a\0b"
        ] do
      assert {:error, :unsafe_file} = Archive.pack(%{path => "x"})
    end

    assert {:error, :file_directory_conflict} = Archive.pack(%{"a" => "x", "a/b" => "y"})
    assert {:error, :unsafe_file} = Archive.pack(%{"a" => %{link: "outside"}})
  end

  test "rejects links, special types, traversal and checksum corruption without extraction" do
    assert {:ok, archive} = Archive.pack(%{"safe" => "x"})
    tar = :zlib.gunzip(archive)

    for type <- [?1, ?2, ?3, ?6, ?x, ?L] do
      malicious = patch_header(tar, 156, <<type>>)
      assert {:error, :unsafe_or_invalid_header} = Archive.unpack(:zlib.gzip(malicious))
    end

    assert {:error, :unsafe_or_invalid_header} =
             Archive.unpack(
               :zlib.gzip(patch_header(tar, 0, "../escape" <> :binary.copy(<<0>>, 91)))
             )

    <<_, rest::binary>> = tar
    assert {:error, :unsafe_or_invalid_header} = Archive.unpack(:zlib.gzip("X" <> rest))
    assert {:error, _} = Archive.unpack("not gzip")
    assert {:error, _} = Archive.unpack(binary_part(archive, 0, byte_size(archive) - 4))
  end

  test "enforces compressed, decompressed, entry, file and aggregate limits" do
    assert {:ok, archive} = Archive.pack(%{"a" => String.duplicate("x", 100_000)})
    assert {:error, :archive_too_large} = Archive.unpack(archive, max_archive_bytes: 1)
    assert {:error, :decompression_limit} = Archive.unpack(archive, max_uncompressed_bytes: 1024)
    assert {:error, _} = Archive.unpack(archive, max_file_bytes: 1)
    assert {:error, _} = Archive.unpack(archive, max_entries: 0)
    assert {:error, _} = Archive.unpack(archive, max_total_bytes: 1)
    assert {:error, :too_many_files} = Archive.unpack(archive, max_files: 0)
  end

  test "rejects duplicate entries and nonzero data after tar terminator" do
    assert {:ok, archive} = Archive.pack(%{"safe" => "x"})
    tar = :zlib.gunzip(archive)
    <<entry::binary-size(1024), ending::binary>> = tar

    assert {:error, :invalid_or_excessive_entry} =
             Archive.unpack(:zlib.gzip(entry <> entry <> ending))

    assert {:error, :trailing_data} = Archive.unpack(:zlib.gzip(tar <> "hidden"))
  end

  @tag :tmp_dir
  test "empty directory at MCP location is a component error", %{tmp_dir: root} do
    File.write!(
      Path.join(root, "plugin.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name" => "demo"
      })
    )

    File.mkdir!(Path.join(root, "mcp.json"))

    assert {:ok, %{diagnostics: [%{code: :invalid_mcp_location}]}} =
             Backplane.PluginProtocol.load_directory(root)
  end

  @tag :tmp_dir
  test "directory loading retains complete resources and rejects symlinks", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "skills/demo/assets"))

    File.write!(
      Path.join(root, "plugin.json"),
      JSON.encode!(%{
        "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name" => "demo"
      })
    )

    File.write!(
      Path.join(root, "skills/demo/SKILL.md"),
      "---\nname: demo\ndescription: Example.\n---\nInstructions"
    )

    File.write!(Path.join(root, "skills/demo/assets/blob"), <<0, 255>>)
    File.chmod!(Path.join(root, "skills/demo/assets/blob"), 0o755)

    assert {:ok, %{modes: %{"skills/demo/assets/blob" => 0o755}}} =
             Archive.read_directory_with_metadata(root)

    assert {:ok, %{skills: [%{name: "demo"}], files: files}} =
             Backplane.PluginProtocol.load_directory(root)

    assert files["skills/demo/assets/blob"] == <<0, 255>>
    File.ln_s!("/etc/passwd", Path.join(root, "outside"))
    assert {:error, {:unsafe_file_type, "outside"}} = Archive.read_directory(root)

    assert {:ok, %{skills: [%{name: "demo"}], diagnostics: [%{code: :unsafe_package_path}]}} =
             Backplane.PluginProtocol.load_directory(root)
  end

  defp patch_header(tar, offset, bytes) do
    <<header::binary-size(512), rest::binary>> = tar
    <<first::binary-size(offset), _old::binary-size(byte_size(bytes)), last::binary>> = header
    modified = first <> bytes <> last
    <<a::binary-size(148), _::binary-size(8), b::binary>> = modified
    checksum = (a <> "        " <> b) |> :binary.bin_to_list() |> Enum.sum()
    a <> String.pad_leading(Integer.to_string(checksum, 8), 6, "0") <> <<0, 32>> <> b <> rest
  end
end
