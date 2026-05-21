defmodule Backplane.SkillArchiveCase do
  @moduledoc false

  def skill_md(name \\ "archive-skill") do
    """
    ---
    name: #{name}
    description: Archive-backed skill
    tags: [archive, test]
    ---

    # #{name}

    Use this skill from an uploaded archive.
    """
  end

  def meta_json(attrs \\ %{}) do
    %{
      "schema" => "backplane.skill.meta/v1",
      "slug" => "archive-skill",
      "version" => "1.2.0",
      "license" => "MIT",
      "homepage" => "https://example.com/archive-skill",
      "source" => %{
        "kind" => "git",
        "uri" => "https://github.com/org/repo",
        "rev" => "abc123"
      }
    }
    |> Map.merge(attrs)
    |> Jason.encode!()
  end

  def tar_gz(entries) do
    entries
    |> Enum.map(&tar_entry/1)
    |> IO.iodata_to_binary()
    |> Kernel.<>(<<0::size(512 * 8), 0::size(512 * 8)>>)
    |> :zlib.gzip()
  end

  defp tar_entry({path, :dir}), do: header(path, 0, "5")
  defp tar_entry({path, {:symlink, target}}), do: header(path, 0, "2", target)

  defp tar_entry({path, content}) when is_binary(content) do
    padding = rem(512 - rem(byte_size(content), 512), 512)
    [header(path, byte_size(content), "0"), content, :binary.copy(<<0>>, padding)]
  end

  defp header(path, size, typeflag, linkname \\ "") do
    header =
      [
        pad(path, 100),
        octal(0o644, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        String.duplicate(" ", 8),
        typeflag,
        pad(linkname, 100),
        "ustar",
        <<0>>,
        "00",
        pad("", 32),
        pad("", 32),
        pad("", 8),
        pad("", 8),
        pad("", 155),
        pad("", 12)
      ]
      |> IO.iodata_to_binary()

    checksum =
      header
      |> :binary.bin_to_list()
      |> Enum.sum()
      |> Integer.to_string(8)
      |> String.pad_leading(6, "0")

    binary_part(header, 0, 148) <> checksum <> <<0, ?\s>> <> binary_part(header, 156, 356)
  end

  defp pad(value, size) do
    value
    |> to_string()
    |> String.slice(0, size)
    |> String.pad_trailing(size, <<0>>)
  end

  defp octal(value, size) do
    value
    |> Integer.to_string(8)
    |> String.pad_leading(size - 1, "0")
    |> Kernel.<>(<<0>>)
  end
end
