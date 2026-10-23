defmodule Backplane.PluginProtocol.Archive do
  @moduledoc """
  Deterministic USTAR gzip snapshots with bounded, memory-only decoding.

  Supports regular files and directories; rejects links, special entries, PAX/GNU
  extensions, duplicate paths, traversal, conflicting paths and invalid checksums.
  `pack/2` writes regular files with mode 0644 by default, uid/gid/mtime zero and
  sorted paths. Supply `modes: %{path => 0o755}` to preserve executable resources.
  No archive path is ever extracted directly to the filesystem.
  """
  alias Backplane.PluginProtocol.Path, as: PackagePath
  @block 512

  def pack(files, opts \\ []) do
    modes = Keyword.get(opts, :modes, %{})

    with :ok <- PackagePath.validate_files(files),
         :ok <- validate_modes(modes, files) do
      entries =
        files
        |> Enum.sort()
        |> Enum.map(fn {path, bytes} ->
          [
            header(path, byte_size(bytes), Map.get(modes, path, 0o644)),
            bytes,
            :binary.copy(<<0>>, padding(byte_size(bytes)))
          ]
        end)

      {:ok, :zlib.gzip(IO.iodata_to_binary([entries, :binary.copy(<<0>>, 1024)]))}
    end
  rescue
    ArgumentError -> {:error, :path_too_long}
  end

  def unpack(bytes, opts \\ []) do
    with {:ok, snapshot} <- unpack_with_metadata(bytes, opts), do: {:ok, snapshot.files}
  end

  def unpack_with_metadata(bytes, opts \\ [])

  def unpack_with_metadata(bytes, opts) when is_binary(bytes) do
    if byte_size(bytes) > Keyword.get(opts, :max_archive_bytes, 33_554_432) do
      {:error, :archive_too_large}
    else
      with {:ok, tar} <- inflate(bytes, Keyword.get(opts, :max_uncompressed_bytes, 80_000_000)),
           {:ok, snapshot} <- entries(tar, %{}, %{}, 0, 0, opts),
           :ok <- PackagePath.validate_files(snapshot.files, opts) do
        {:ok, snapshot}
      end
    end
  rescue
    _ -> {:error, :invalid_archive}
  end

  def unpack_with_metadata(_, _), do: {:error, :invalid_archive}

  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "Reads regular files without following directory or file symlinks."
  def read_directory(root, opts \\ []) do
    with {:ok, %{type: :directory}} <- File.lstat(root),
         {:ok, files, _} <- walk(Path.expand(root), "", %{}, 0, opts),
         :ok <- PackagePath.validate_files(files, opts) do
      {:ok, files}
    else
      {:ok, _} -> {:error, :not_directory}
      error -> error
    end
  end

  @doc "Returns regular-file bytes and low permission bits (no privileged mode bits)."
  def read_directory_with_metadata(root, opts \\ []) do
    with {:ok, files} <- read_directory(root, opts) do
      Enum.reduce_while(files, {:ok, %{files: files, modes: %{}}}, fn {path, _},
                                                                      {:ok, snapshot} ->
        case File.lstat(Path.join(root, path)) do
          {:ok, %{type: :regular, mode: mode}} ->
            {:cont,
             {:ok, %{snapshot | modes: Map.put(snapshot.modes, path, Bitwise.band(mode, 0o777))}}}

          _ ->
            {:halt, {:error, {:unsafe_file_type, path}}}
        end
      end)
    end
  end

  defp validate_modes(modes, files) when is_map(modes) do
    if Enum.all?(modes, fn {path, mode} ->
         Map.has_key?(files, path) and is_integer(mode) and mode in 0..0o777
       end),
       do: :ok,
       else: {:error, :invalid_modes}
  end

  defp validate_modes(_, _), do: {:error, :invalid_modes}

  defp walk(root, relative, files, count, opts) do
    with {:ok, children} <- File.ls(Path.join(root, relative)) do
      Enum.reduce_while(Enum.sort(children), {:ok, files, count}, fn child, {:ok, acc, n} ->
        path = if relative == "", do: child, else: relative <> "/" <> child
        result = read_entry(root, path, acc, n, opts)

        case result do
          {:ok, _, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp read_entry(root, path, files, count, opts) do
    cond do
      not PackagePath.safe?(path) ->
        {:error, {:unsafe_path, path}}

      count >= Keyword.get(opts, :max_entries, 20_000) ->
        {:error, :too_many_entries}

      length(String.split(path, "/")) > Keyword.get(opts, :max_depth, 64) ->
        {:error, :tree_too_deep}

      true ->
        case File.lstat(Path.join(root, path)) do
          {:ok, %{type: :directory}} ->
            walk(root, path, files, count + 1, opts)

          {:ok, %{type: :regular, size: size}} ->
            if size <= Keyword.get(opts, :max_file_bytes, 16_777_216) do
              with {:ok, bytes} <- File.read(Path.join(root, path)),
                   next = Map.put(files, path, bytes),
                   :ok <- PackagePath.validate_files(next, opts),
                   {:ok, %{type: :regular}} <- File.lstat(Path.join(root, path)) do
                {:ok, next, count + 1}
              end
            else
              {:error, :file_too_large}
            end

          {:ok, _} ->
            {:error, {:unsafe_file_type, path}}

          error ->
            error
        end
    end
  end

  defp inflate(bytes, limit) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate_chunks(z, bytes, [], 0, limit)
    catch
      :error, _ -> {:error, :invalid_gzip}
    after
      :zlib.close(z)
    end
  end

  defp inflate_chunks(z, bytes, acc, size, limit) do
    {status, output} = :zlib.safeInflate(z, bytes)
    next_size = size + IO.iodata_length(output)

    cond do
      next_size > limit ->
        {:error, :decompression_limit}

      status == :continue ->
        inflate_chunks(z, <<>>, [output | acc], next_size, limit)

      status == :finished ->
        :ok = :zlib.inflateEnd(z)
        {:ok, acc |> then(&[output | &1]) |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp entries(<<0::size(8192), rest::binary>>, files, seen, _count, _size, _opts) do
    modes = Map.new(for {path, {:file, mode}} <- seen, do: {path, mode})

    if rest == :binary.copy(<<0>>, byte_size(rest)),
      do: {:ok, %{files: files, modes: modes}},
      else: {:error, :trailing_data}
  end

  defp entries(<<header::binary-size(@block), rest::binary>>, files, seen, count, total, opts) do
    with true <- count < Keyword.get(opts, :max_entries, 20_000),
         {:ok, path, size, type, mode} <- parse_header(header),
         true <- compatible_entry?(seen, path, type),
         true <- size <= Keyword.get(opts, :max_file_bytes, 16_777_216),
         true <- total + size <= Keyword.get(opts, :max_total_bytes, 67_108_864),
         pad = padding(size),
         true <- byte_size(rest) >= size + pad,
         <<body::binary-size(size), _pad::binary-size(pad), remaining::binary>> <- rest do
      next = if type == :file, do: Map.put(files, path, body), else: files
      entries(remaining, next, Map.put(seen, path, {type, mode}), count + 1, total + size, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_or_excessive_entry}
    end
  end

  defp entries(_, _, _, _, _, _), do: {:error, :truncated_archive}

  defp compatible_entry?(seen, path, type) do
    not Map.has_key?(seen, path) and
      Enum.all?(seen, fn {existing, {existing_type, _mode}} ->
        not (existing_type == :file and String.starts_with?(path, existing <> "/")) and
          not (type == :file and String.starts_with?(existing, path <> "/"))
      end)
  end

  defp parse_header(header) do
    <<name::binary-size(100), mode::binary-size(8), _::binary-size(16), size::binary-size(12),
      _::binary-size(12), checksum::binary-size(8), type, link::binary-size(100),
      magic::binary-size(6), _::binary-size(82), prefix::binary-size(155), _::binary>> = header

    name = trim(name)
    prefix = trim(prefix)
    path = if prefix == "", do: name, else: prefix <> "/" <> name
    path = if type == ?5, do: String.trim_trailing(path, "/"), else: path
    <<first::binary-size(148), _::binary-size(8), last::binary>> = header
    expected = :binary.bin_to_list(first <> "        " <> last) |> Enum.sum()

    with true <- magic in ["ustar\0", "ustar "],
         true <- trim(link) == "",
         true <- PackagePath.safe?(path),
         {:ok, ^expected} <- octal(checksum),
         {:ok, size} <- octal(size),
         {:ok, mode} <- octal(mode),
         true <- type in [0, ?0, ?5],
         true <- type != ?5 or size == 0 do
      {:ok, path, size, if(type == ?5, do: :directory, else: :file), Bitwise.band(mode, 0o777)}
    else
      _ -> {:error, :unsafe_or_invalid_header}
    end
  end

  defp header(path, size, mode) do
    {name, prefix} = split_name(path)

    base =
      field(name, 100) <>
        octal_field(mode, 8) <>
        octal_field(0, 8) <>
        octal_field(0, 8) <>
        octal_field(size, 12) <>
        octal_field(0, 12) <>
        "        " <>
        "0" <>
        field("", 100) <>
        "ustar\0" <>
        "00" <>
        field("", 32) <>
        field("", 32) <>
        octal_field(0, 8) <>
        octal_field(0, 8) <>
        field(prefix, 155) <> :binary.copy(<<0>>, 12)

    checksum = base |> :binary.bin_to_list() |> Enum.sum()
    <<first::binary-size(148), _::binary-size(8), rest::binary>> = base
    first <> (Integer.to_string(checksum, 8) |> String.pad_leading(6, "0")) <> <<0, 32>> <> rest
  end

  defp split_name(path) when byte_size(path) <= 100, do: {path, ""}

  defp split_name(path) do
    split =
      path
      |> :binary.matches("/")
      |> Enum.reverse()
      |> Enum.find(fn {index, _} ->
        index <= 155 and byte_size(path) - index - 1 <= 100
      end)

    case split do
      {index, _} ->
        {binary_part(path, index + 1, byte_size(path) - index - 1), binary_part(path, 0, index)}

      nil ->
        raise ArgumentError, "USTAR path too long"
    end
  end

  defp field(value, size), do: value <> :binary.copy(<<0>>, size - byte_size(value))

  defp octal_field(value, size),
    do: String.pad_leading(Integer.to_string(value, 8), size - 1, "0") <> <<0>>

  defp trim(value), do: value |> String.split(<<0>>, parts: 2) |> hd()

  defp octal(value) do
    value = value |> trim() |> String.trim()

    if Regex.match?(~r/\A[0-7]+\z/, value) do
      case Integer.parse(value, 8) do
        {n, ""} -> {:ok, n}
        _ -> :error
      end
    else
      :error
    end
  end

  defp padding(size), do: rem(@block - rem(size, @block), @block)
end
