defmodule Backplane.Skills.Archive do
  @moduledoc """
  Validates and reads uploaded `.tar.gz` skill archives.
  """

  alias Backplane.Skills.{Loader, Skill}

  @default_max_files 500
  @block_size 512

  @type info :: %{
          skill_md: String.t(),
          skill_entry: map(),
          meta: map(),
          files: [String.t()],
          file_count: non_neg_integer(),
          size_bytes: non_neg_integer()
        }

  @spec inspect(binary(), keyword()) :: {:ok, info()} | {:error, atom()}
  def inspect(archive, opts \\ []) when is_binary(archive) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)

    with {:ok, entries} <- entries(archive),
         :ok <- validate_file_count(entries, max_files),
         {:ok, root, skill_md} <- find_skill_md(entries),
         :ok <- validate_root(entries, root),
         {:ok, meta} <- read_meta(entries, root),
         {:ok, skill_entry} <- parse_skill_entry(skill_md, meta, root, opts) do
      files =
        entries
        |> Enum.filter(&(&1.type == :file))
        |> Enum.map(&strip_root(&1.path, root))
        |> Enum.sort()

      {:ok,
       %{
         skill_md: skill_md,
         skill_entry: skill_entry,
         meta: meta,
         files: files,
         file_count: length(files),
         size_bytes: byte_size(archive)
       }}
    end
  end

  defp entries(archive) do
    case gunzip(archive) do
      {:ok, tar} -> parse_entries(tar, [])
      {:error, reason} -> {:error, reason}
    end
  end

  defp gunzip(archive) do
    {:ok, :zlib.gunzip(archive)}
  rescue
    _ -> {:error, :invalid_archive}
  end

  defp parse_entries(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_entries(<<header::binary-size(@block_size), rest::binary>>, acc) do
    if zero_block?(header) do
      {:ok, Enum.reverse(acc)}
    else
      with {:ok, entry, remaining} <- parse_entry(header, rest) do
        parse_entries(remaining, [entry | acc])
      end
    end
  end

  defp parse_entries(_partial, _acc), do: {:error, :invalid_archive}

  defp parse_entry(header, rest) do
    with {:ok, path} <- entry_path(header),
         :ok <- validate_path(path),
         {:ok, size} <- entry_size(header) do
      typeflag = binary_part(header, 156, 1)

      case typeflag do
        flag when flag in [<<0>>, "0"] ->
          read_file_entry(path, size, rest)

        "5" ->
          {:ok, %{path: trim_directory(path), type: :directory}, rest}

        _ ->
          {:error, :unsupported_entry}
      end
    end
  end

  defp read_file_entry(path, size, rest) when byte_size(rest) >= size do
    <<content::binary-size(size), tail::binary>> = rest
    padding = rem(@block_size - rem(size, @block_size), @block_size)

    if byte_size(tail) >= padding do
      <<_pad::binary-size(padding), remaining::binary>> = tail
      {:ok, %{path: path, type: :file, content: content}, remaining}
    else
      {:error, :invalid_archive}
    end
  end

  defp read_file_entry(_path, _size, _rest), do: {:error, :invalid_archive}

  defp entry_path(header) do
    name = header |> binary_part(0, 100) |> cstring()
    prefix = header |> binary_part(345, 155) |> cstring()

    path =
      case {prefix, name} do
        {"", name} -> name
        {prefix, name} -> prefix <> "/" <> name
      end

    if path == "", do: {:error, :invalid_archive}, else: {:ok, path}
  end

  defp entry_size(header) do
    header
    |> binary_part(124, 12)
    |> cstring()
    |> String.trim()
    |> case do
      "" -> {:ok, 0}
      value -> parse_octal(value)
    end
  end

  defp parse_octal(value) do
    case Integer.parse(value, 8) do
      {size, ""} -> {:ok, size}
      _ -> {:error, :invalid_archive}
    end
  end

  defp validate_path(path) do
    trimmed = trim_directory(path)
    segments = String.split(trimmed, "/", trim: true)

    cond do
      trimmed == "" -> {:error, :unsafe_path}
      String.starts_with?(trimmed, ["/", "\\"]) -> {:error, :unsafe_path}
      String.match?(trimmed, ~r/^[A-Za-z]:/) -> {:error, :unsafe_path}
      String.contains?(trimmed, "\\") -> {:error, :unsafe_path}
      String.contains?(trimmed, "//") -> {:error, :unsafe_path}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :unsafe_path}
      true -> :ok
    end
  end

  defp validate_file_count(entries, max_files) do
    file_count = Enum.count(entries, &(&1.type == :file))

    if file_count > max_files, do: {:error, :too_many_files}, else: :ok
  end

  defp find_skill_md(entries) do
    case Enum.find(entries, &(&1.type == :file and Path.basename(&1.path) == "SKILL.md")) do
      nil -> {:error, :missing_skill_md}
      entry -> {:ok, Path.dirname(entry.path), entry.content}
    end
  end

  defp validate_root(_entries, "."), do: :ok

  defp validate_root(entries, root) do
    prefix = root <> "/"

    if Enum.all?(entries, &(&1.path == root or String.starts_with?(&1.path, prefix))) do
      :ok
    else
      {:error, :unsafe_path}
    end
  end

  defp read_meta(entries, root) do
    meta_path = join_root(root, "meta.json")

    case Enum.find(entries, &(&1.type == :file and &1.path == meta_path)) do
      nil ->
        {:ok, %{}}

      %{content: content} ->
        case Jason.decode(content) do
          {:ok, meta} when is_map(meta) -> {:ok, meta}
          _ -> {:error, :malformed_meta}
        end
    end
  end

  defp parse_skill_entry(skill_md, meta, root, opts) do
    case Loader.parse(skill_md) do
      {:ok, skill_entry} ->
        {:ok, Map.put(skill_entry, :slug, resolve_slug(meta, skill_entry, root, opts))}

      {:error, :missing_frontmatter} ->
        fallback = fallback_name(meta, root, opts)
        content = markdown_body(skill_md)
        hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        {:ok,
         %{
           slug: Skill.slugify(fallback),
           name: fallback,
           description: "",
           tags: [],
           content: content,
           content_hash: hash
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_slug(meta, skill_entry, root, opts) do
    meta
    |> Map.get("slug")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> Map.get(skill_entry, :name) || fallback_name(meta, root, opts)
    end
    |> Skill.slugify()
  end

  defp fallback_name(meta, root, opts) do
    cond do
      is_binary(Map.get(meta, "slug")) and Map.get(meta, "slug") != "" ->
        Map.get(meta, "slug")

      is_binary(Keyword.get(opts, :slug_fallback)) and Keyword.get(opts, :slug_fallback) != "" ->
        Keyword.get(opts, :slug_fallback)

      root not in [nil, "."] ->
        Path.basename(root)

      true ->
        "skill"
    end
  end

  defp markdown_body(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      [_before, _yaml, body] -> String.trim(body)
      _ -> String.trim(content)
    end
  end

  defp strip_root(path, "."), do: path
  defp strip_root(path, root), do: String.replace_prefix(path, root <> "/", "")

  defp join_root(".", path), do: path
  defp join_root(root, path), do: root <> "/" <> path

  defp trim_directory(path), do: String.trim_trailing(path, "/")

  defp zero_block?(block), do: block == :binary.copy(<<0>>, @block_size)

  defp cstring(binary) do
    binary
    |> :binary.split(<<0>>)
    |> hd()
  end
end
