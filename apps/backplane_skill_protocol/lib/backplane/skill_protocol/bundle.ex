defmodule Backplane.SkillProtocol.Bundle do
  @moduledoc "Bounded inspection, packing, and atomic preparation of complete Skill bundles."

  import Kernel, except: [inspect: 1, inspect: 2]

  alias Backplane.SkillProtocol.{
    BundleManifest,
    Document,
    Error,
    Parser,
    PathSafety,
    PreparedSkill,
    SkillRef,
    TemporaryStorage,
    Validator
  }

  @default_max_compressed_bytes 16 * 1024 * 1024
  @default_max_expanded_bytes 64 * 1024 * 1024
  @default_max_file_bytes 8 * 1024 * 1024
  @default_max_entries 1_000
  @default_max_path_depth 16

  @enforce_keys [:archive_path, :manifest, :document, :files]
  defstruct [:archive_path, :manifest, :document, :meta, :files]

  @type t :: %__MODULE__{}

  @spec inspect(String.t() | %{path: String.t()}, keyword()) :: {:ok, t()} | {:error, Error.t()}
  def inspect(path_or_upload, opts \\ []) do
    with {:ok, path} <- archive_path(path_or_upload),
         {:ok, stat} <- File.stat(path),
         :ok <-
           maximum(
             stat.size,
             limit(opts, :max_compressed_bytes, @default_max_compressed_bytes),
             :compressed_bytes
           ),
         :ok <- cancelled(opts),
         result <- with_tar(path, opts, &inspect_tar(&1, path, stat.size, opts)) do
      result
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        error(:invalid_bundle, "archive cannot be read", %{reason: Kernel.inspect(reason)})
    end
  end

  @spec prepare(String.t() | %{path: String.t()} | t(), String.t(), keyword()) ::
          {:ok, PreparedSkill.t()} | {:error, Error.t()}
  def prepare(path_or_bundle, destination, opts \\ []) when is_binary(destination) do
    with {:ok, bundle} <- ensure_bundle(path_or_bundle, opts),
         :ok <- cancelled(opts),
         {:ok, stage} <- staging_path(destination),
         result <- write_and_publish(bundle, stage, destination, opts) do
      result
    end
  end

  @spec pack(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def pack(skill_root, archive_path, opts \\ []) do
    with {:ok, canonical_root} <- realpath(skill_root),
         false <- path_exists?(archive_path),
         {:ok, stage} <- pack_staging_path(archive_path),
         {:ok, bundle} <- pack_and_publish(canonical_root, archive_path, stage, opts) do
      {:ok, bundle}
    else
      true ->
        error(:invalid_request, "bundle archive already exists")

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        error(:invalid_bundle, "bundle cannot be packed", %{reason: sanitized_reason(reason)})
    end
  end

  def artifact_digest(bytes) when is_binary(bytes),
    do: "sha256:" <> (:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower))

  defp inspect_tar(tar_path, archive_path, compressed_bytes, opts) do
    with {:ok, raw_entries} <- :erl_tar.table(String.to_charlist(tar_path), [:verbose]),
         :ok <-
           maximum(
             length(raw_entries),
             limit(opts, :max_entries, @default_max_entries),
             :archive_entries
           ),
         {:ok, entries} <- normalize_entries(raw_entries, opts),
         {:ok, root, entrypoint} <- root_and_entrypoint(entries),
         :ok <- validate_collisions(entries),
         :ok <- validate_sizes(entries, opts),
         :ok <- cancelled(opts),
         {:ok, files} <- extract_files(tar_path, entries),
         {:ok, skill_bytes} <- Map.fetch(files, entrypoint),
         {:ok, document} <- Parser.parse(skill_bytes, parser_opts(opts)),
         {:ok, document} <- Validator.validate(document, validator_opts(opts)),
         :ok <- validate_directory_name(document, root, opts),
         {:ok, archive_bytes} <- File.read(archive_path) do
      relative_files =
        entries
        |> Enum.filter(&(&1.type == :regular))
        |> Enum.map(fn entry ->
          relative = Path.relative_to(entry.name, root)
          bytes = Map.fetch!(files, entry.name)
          %{path: relative, bytes: byte_size(bytes), sha256: sha256(bytes)}
        end)
        |> Enum.sort_by(& &1.path)

      ref = Keyword.get(opts, :ref)

      manifest = %BundleManifest{
        protocol_version: Backplane.SkillProtocol.protocol_version(),
        profile: Backplane.SkillProtocol.bundle_profile(),
        ref: normalize_ref(ref, artifact_digest(archive_bytes)),
        root: root,
        entrypoint: Path.relative_to(entrypoint, root),
        document_metadata: document.metadata,
        artifact_format: "tar+gzip",
        artifact_digest: artifact_digest(archive_bytes),
        compressed_bytes: compressed_bytes,
        unpacked_bytes: Enum.sum(Enum.map(relative_files, & &1.bytes)),
        required_capabilities: required_capabilities(document.metadata),
        files: relative_files
      }

      relative_content =
        Map.new(files, fn {name, bytes} -> {Path.relative_to(name, root), bytes} end)

      meta = decode_meta(relative_content["meta.json"])

      case meta do
        {:ok, value} ->
          {:ok,
           %__MODULE__{
             archive_path: archive_path,
             manifest: manifest,
             document: document,
             meta: value,
             files: relative_content
           }}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    else
      :error ->
        error(:invalid_bundle, "bundle entrypoint content is missing")

      {:error, %Error{} = reason} ->
        {:error, reason}

      {:error, reason} ->
        error(:invalid_bundle, "archive is malformed", %{reason: Kernel.inspect(reason)})
    end
  end

  defp with_tar(gzip_path, opts, callback) do
    with {:ok, dir} <- temporary_directory("backplane-skill-protocol") do
      tmp = Path.join(dir, "archive.tar")

      try do
        with :ok <- inflate_bounded(gzip_path, tmp, opts), do: callback.(tmp)
      after
        File.rm_rf(dir)
      end
    end
  end

  defp inflate_bounded(source, target, opts) do
    max = limit(opts, :max_expanded_bytes, @default_max_expanded_bytes)

    case File.open(source, [:read, :binary]) do
      {:ok, input} ->
        case TemporaryStorage.open_file(target) do
          {:ok, output} ->
            z = :zlib.open()

            try do
              :ok = :zlib.inflateInit(z, 31)

              input
              |> IO.binstream(64 * 1024)
              |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, total} ->
                with :ok <- cancelled(opts),
                     inflated = z |> :zlib.inflate(chunk) |> IO.iodata_to_binary(),
                     next = total + byte_size(inflated),
                     :ok <- maximum(next, max, :expanded_bytes),
                     :ok <- IO.binwrite(output, inflated) do
                  {:cont, {:ok, next}}
                else
                  {:error, _} = error -> {:halt, error}
                end
              end)
              |> case do
                {:ok, _total} -> :ok
                {:error, _} = error -> error
              end
            catch
              _, _ -> error(:invalid_bundle, "archive gzip stream is malformed")
            after
              :zlib.close(z)
              File.close(input)
              File.close(output)
            end

          {:error, reason} ->
            File.close(input)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_entries(entries, opts) do
    Enum.reduce_while(entries, {:ok, []}, fn raw, {:ok, acc} ->
      with {:ok, entry} <- normalize_entry(raw),
           :ok <- validate_path(entry.name, opts),
           :ok <- validate_type(entry) do
        {:cont, {:ok, [entry | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_entry({name, type, size, _mtime, _mode, _uid, _gid}),
    do: {:ok, %{name: normalize_name(name), type: type, size: size}}

  defp normalize_entry({name, size, type}),
    do: {:ok, %{name: normalize_name(name), type: type, size: size}}

  defp normalize_entry(_), do: error(:invalid_bundle, "archive contains a malformed entry")

  defp normalize_name(name), do: name |> IO.chardata_to_string() |> String.trim_trailing("/")

  defp validate_type(%{type: type}) when type in [:regular, :directory], do: :ok

  defp validate_type(%{name: name, type: type}),
    do: error(:invalid_bundle, "archive entry type is unsupported", %{path: name, type: type})

  defp validate_path(name, opts) do
    segments = String.split(name, "/", trim: false)
    max_depth = limit(opts, :max_path_depth, @default_max_path_depth)

    cond do
      name == "" or Path.type(name) == :absolute ->
        unsafe(name)

      String.contains?(name, "\\") ->
        unsafe(name)

      ".." in segments or "" in segments or "." in segments ->
        unsafe(name)

      Enum.any?(segments, &Regex.match?(~r/^[A-Za-z]:/, &1)) ->
        unsafe(name)

      Enum.any?(segments, &Regex.match?(~r/%2e/i, &1)) ->
        unsafe(name)

      length(segments) > max_depth ->
        error(:limit_exceeded, "archive path depth exceeds limit", %{path: name, limit: max_depth})

      true ->
        :ok
    end
  end

  defp root_and_entrypoint(entries) do
    roots = entries |> Enum.map(&(&1.name |> String.split("/", parts: 2) |> hd())) |> Enum.uniq()

    case roots do
      [root] ->
        entrypoint = root <> "/SKILL.md"

        if Enum.any?(entries, &(&1.name == entrypoint and &1.type == :regular)),
          do: {:ok, root, entrypoint},
          else: error(:invalid_bundle, "bundle root has no SKILL.md")

      _ ->
        error(:invalid_bundle, "bundle must contain exactly one logical root")
    end
  end

  defp validate_collisions(entries) do
    Enum.reduce_while(entries, {:ok, MapSet.new(), MapSet.new()}, fn entry,
                                                                     {:ok, exact, folded} ->
      key = String.downcase(entry.name)

      cond do
        MapSet.member?(exact, entry.name) ->
          {:halt, error(:invalid_bundle, "archive has duplicate targets", %{path: entry.name})}

        MapSet.member?(folded, key) ->
          {:halt, error(:invalid_bundle, "archive has colliding targets", %{path: entry.name})}

        parent_file?(entry.name, entries) ->
          {:halt,
           error(:invalid_bundle, "archive has a file/directory conflict", %{path: entry.name})}

        true ->
          {:cont, {:ok, MapSet.put(exact, entry.name), MapSet.put(folded, key)}}
      end
    end)
    |> case do
      {:ok, _, _} -> :ok
      error -> error
    end
  end

  defp parent_file?(name, entries) do
    parts = String.split(name, "/")

    parts
    |> Enum.drop(-1)
    |> Enum.scan([], fn part, acc -> acc ++ [part] end)
    |> Enum.map(&Enum.join(&1, "/"))
    |> Enum.any?(fn parent ->
      Enum.any?(entries, &(&1.name == parent and &1.type == :regular))
    end)
  end

  defp validate_sizes(entries, opts) do
    regular = Enum.filter(entries, &(&1.type == :regular))
    max_file = limit(opts, :max_file_bytes, @default_max_file_bytes)
    max_total = limit(opts, :max_expanded_bytes, @default_max_expanded_bytes)

    case Enum.find(regular, &(&1.size > max_file)) do
      nil ->
        maximum(Enum.sum(Enum.map(regular, & &1.size)), max_total, :unpacked_bytes)

      entry ->
        error(:limit_exceeded, "archive file exceeds limit", %{
          path: entry.name,
          actual: entry.size,
          limit: max_file
        })
    end
  end

  defp extract_files(tar_path, entries) do
    names =
      entries |> Enum.filter(&(&1.type == :regular)) |> Enum.map(&String.to_charlist(&1.name))

    case :erl_tar.extract(String.to_charlist(tar_path), [:memory, {:files, names}]) do
      {:ok, extracted} ->
        {:ok,
         Map.new(extracted, fn {name, bytes} ->
           {IO.chardata_to_string(name), IO.iodata_to_binary(bytes)}
         end)}

      {:error, reason} ->
        error(:invalid_bundle, "archive contents cannot be extracted", %{
          reason: Kernel.inspect(reason)
        })
    end
  end

  defp validate_directory_name(%Document{name: name}, root, opts) do
    if Keyword.get(opts, :validate_directory_name, true) == false or name == root do
      :ok
    else
      error(:invalid_bundle, "document name does not match bundle root", %{name: name, root: root})
    end
  end

  defp decode_meta(nil), do: {:ok, %{}}

  defp decode_meta(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> error(:invalid_bundle, "meta.json must contain a JSON object")
    end
  end

  defp required_capabilities(metadata) do
    case Map.get(metadata, "backplane") do
      extension when is_map(extension) ->
        case Map.get(extension, "required-capabilities") do
          values when is_list(values) -> values
          _ -> []
        end

      _ ->
        []
    end
  end

  defp ensure_bundle(%__MODULE__{} = bundle, _opts), do: {:ok, bundle}
  defp ensure_bundle(path, opts), do: inspect(path, opts)

  defp staging_path(destination) do
    parent = Path.dirname(Path.expand(destination))

    with :ok <- File.mkdir_p(parent),
         {:ok, stage} <- temporary_directory(parent, ".#{Path.basename(destination)}.stage") do
      {:ok, stage}
    end
  end

  defp temporary_directory(prefix), do: temporary_directory(System.tmp_dir!(), prefix)

  defp temporary_directory(parent, prefix) do
    case TemporaryStorage.directory(parent, prefix) do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} ->
        error(:invalid_bundle, "temporary storage cannot be allocated", %{
          reason: Kernel.inspect(reason)
        })
    end
  end

  defp write_and_publish(bundle, stage, destination, opts) do
    try do
      with :ok <- write_files(bundle.files, stage, opts),
           :ok <- cancelled(opts),
           false <- path_exists?(destination),
           :ok <- File.rename(stage, destination) do
        {:ok,
         %PreparedSkill{
           root: Path.expand(destination),
           document: bundle.document,
           manifest: bundle.manifest
         }}
      else
        true ->
          error(:invalid_request, "prepared destination already exists")

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          error(:invalid_bundle, "prepared bundle cannot be published", %{
            reason: Kernel.inspect(reason)
          })
      end
    after
      File.rm_rf(stage)
    end
  end

  defp write_files(files, stage, opts) do
    Enum.reduce_while(Enum.sort(files), :ok, fn {relative, bytes}, :ok ->
      with :ok <- cancelled(opts),
           path = Path.join(stage, relative),
           :ok <- ensure_parent_directories(stage, relative),
           :ok <- TemporaryStorage.write_file(path, bytes) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_parent_directories(stage, relative) do
    relative
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.reduce_while({:ok, stage}, fn segment, {:ok, parent} ->
      path = Path.join(parent, segment)

      case TemporaryStorage.ensure_directory(path) do
        :ok -> {:cont, {:ok, path}}
        {:ok, ^path} -> {:cont, {:ok, path}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_exists?(path), do: match?({:ok, _stat}, File.lstat(path))

  defp pack_staging_path(archive_path) do
    expanded = Path.expand(archive_path)
    temporary_directory(Path.dirname(expanded), ".#{Path.basename(expanded)}.stage")
  end

  defp pack_and_publish(root, archive_path, stage, opts) do
    staged_archive = Path.join(stage, "archive.tar.gz")

    try do
      with {:ok, snapshot} <- collect_directory(root, opts),
           :ok <- require_entrypoint(snapshot.entries),
           :ok <- create_archive(staged_archive, Path.basename(root), snapshot.entries),
           {:ok, bundle} <- inspect(staged_archive, opts),
           {:ok, verification} <- collect_directory(root, opts),
           :ok <- verify_snapshot(snapshot, verification),
           :ok <- cancelled(opts),
           :ok <- publish_archive(staged_archive, archive_path) do
        {:ok, %{bundle | archive_path: archive_path}}
      end
    after
      File.rm_rf(stage)
    end
  end

  defp publish_archive(staged_archive, archive_path) do
    case File.ln(staged_archive, archive_path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        error(:invalid_request, "bundle archive already exists")

      {:error, reason} ->
        error(:invalid_bundle, "bundle archive cannot be published", %{
          reason: sanitized_reason(reason)
        })
    end
  end

  defp collect_directory(root, opts) do
    with :ok <- cancelled(opts),
         {:ok, before} <- File.lstat(root),
         true <- before.type == :directory,
         {:ok, names} <- File.ls(root),
         {:ok, entries, evidence, _count, _total} <-
           collect_children(Enum.sort(names), root, root, opts, [], [], 0, 0),
         {:ok, after_stat} <- File.lstat(root),
         true <- stat_signature(before) == stat_signature(after_stat) do
      {:ok,
       %{
         entries: Enum.reverse(entries),
         evidence:
           Enum.sort([{String.to_charlist("."), stat_signature(after_stat), nil} | evidence])
       }}
    else
      false -> source_changed(:directory_changed)
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> source_changed(:inventory_changed)
    end
  end

  defp collect_children(names, parent, root, opts, entries, evidence, count, total) do
    Enum.reduce_while(names, {:ok, entries, evidence, count, total}, fn name,
                                                                        {:ok, items, proof, c, t} ->
      case collect_path(Path.join(parent, name), root, opts, items, proof, c, t) do
        {:ok, _, _, _, _} = result -> {:cont, result}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp collect_path(path, root, opts, entries, evidence, count, total) do
    with :ok <- cancelled(opts),
         {:ok, link_stat} <- File.lstat(path),
         false <- link_stat.type == :symlink,
         :ok <-
           maximum(count + 1, limit(opts, :max_entries, @default_max_entries), :archive_entries) do
      if link_stat.type == :directory do
        with {:ok, names} <- File.ls(path),
             {:ok, items, proof, next_count, next_total} <-
               collect_children(
                 Enum.sort(names),
                 path,
                 root,
                 opts,
                 entries,
                 evidence,
                 count + 1,
                 total
               ),
             {:ok, after_stat} <- File.lstat(path),
             true <- stat_signature(link_stat) == stat_signature(after_stat) do
          relative = Path.relative_to(path, root)

          {:ok, items, [{String.to_charlist(relative), stat_signature(after_stat), nil} | proof],
           next_count, next_total}
        else
          false -> source_changed(:directory_changed)
          {:error, %Error{} = error} -> {:error, error}
          {:error, _reason} -> source_changed(:inventory_changed)
        end
      else
        with true <- link_stat.type == :regular,
             :ok <-
               maximum(
                 link_stat.size,
                 limit(opts, :max_file_bytes, @default_max_file_bytes),
                 :file_bytes
               ),
             :ok <-
               maximum(
                 total + link_stat.size,
                 limit(opts, :max_expanded_bytes, @default_max_expanded_bytes),
                 :unpacked_bytes
               ),
             {:ok, bytes} <- read_exact_file(path, link_stat.size, opts),
             {:ok, after_stat} <- File.lstat(path),
             true <- stat_signature(link_stat) == stat_signature(after_stat) do
          relative = Path.relative_to(path, root)
          proof = {String.to_charlist(relative), stat_signature(after_stat), sha256(bytes)}

          {:ok, [{relative, bytes} | entries], [proof | evidence], count + 1,
           total + byte_size(bytes)}
        else
          false -> error(:invalid_bundle, "bundle source contains unsupported filesystem entry")
          {:error, %Error{} = error} -> {:error, error}
          {:error, _reason} -> source_changed(:file_changed)
        end
      end
    else
      true -> error(:invalid_bundle, "bundle source contains a symlink")
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> source_changed(:inventory_changed)
    end
  end

  defp read_exact_file(path, expected_size, opts) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          with {:ok, chunks} <- read_exact_chunks(file, expected_size, opts, []),
               :eof <- IO.binread(file, 1) do
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
          else
            extra when is_binary(extra) -> source_changed(:file_changed)
            {:error, %Error{} = error} -> {:error, error}
            {:error, _reason} -> source_changed(:file_changed)
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        source_changed(:file_changed)
    end
  end

  defp read_exact_chunks(_file, 0, _opts, chunks), do: {:ok, chunks}

  defp read_exact_chunks(file, remaining, opts, chunks) do
    with :ok <- cancelled(opts) do
      case IO.binread(file, min(remaining, 64 * 1024)) do
        data when is_binary(data) ->
          read_exact_chunks(file, remaining - byte_size(data), opts, [data | chunks])

        :eof ->
          source_changed(:file_changed)

        {:error, _reason} ->
          source_changed(:file_changed)
      end
    end
  end

  defp verify_snapshot(%{evidence: evidence}, %{evidence: evidence}), do: :ok
  defp verify_snapshot(_snapshot, _verification), do: source_changed(:source_changed)

  defp stat_signature(stat),
    do: {stat.type, stat.inode, stat.size, stat.mtime, stat.ctime}

  defp require_entrypoint(entries) do
    if Enum.any?(entries, &(elem(&1, 0) == "SKILL.md")),
      do: :ok,
      else: error(:invalid_bundle, "bundle root has no SKILL.md")
  end

  defp create_archive(path, root, entries) do
    tar_entries =
      Enum.map(entries, fn {name, bytes} -> {String.to_charlist(Path.join(root, name)), bytes} end)

    case :erl_tar.create(String.to_charlist(path), tar_entries, [:compressed]),
      do: (
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      )
  end

  defp normalize_ref(nil, _digest), do: nil
  defp normalize_ref(%SkillRef{} = ref, digest), do: %{ref | artifact_digest: digest}

  defp parser_opts(opts),
    do: Keyword.take(opts, [:max_document_bytes, :max_frontmatter_bytes, :max_nesting_depth])

  defp validator_opts(opts),
    do: [
      profile: Keyword.get(opts, :validation_profile, :standard),
      supported_capabilities: Keyword.get(opts, :supported_capabilities, [])
    ]

  defp archive_path(path) when is_binary(path), do: {:ok, path}
  defp archive_path(%{path: path}) when is_binary(path), do: {:ok, path}
  defp archive_path(_), do: error(:invalid_request, "archive path is invalid")
  defp limit(opts, key, default), do: Keyword.get(opts, key, default)
  defp maximum(actual, maximum, _budget) when actual <= maximum, do: :ok

  defp maximum(actual, maximum, budget),
    do:
      error(:limit_exceeded, "bundle budget exceeded", %{
        budget: budget,
        actual: actual,
        limit: maximum
      })

  defp cancelled(opts),
    do:
      if(Keyword.get(opts, :cancelled?, fn -> false end).(),
        do: error(:cancelled, "bundle operation was cancelled"),
        else: :ok
      )

  defp unsafe(path), do: error(:invalid_bundle, "archive path is unsafe", %{path: path})
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp source_changed(change),
    do:
      {:error,
       Error.new(:source_changed, :bundle, "bundle source changed while packing",
         context: %{change: change},
         retryable: true
       )}

  defp sanitized_reason(reason) when is_atom(reason), do: reason

  defp sanitized_reason({operation, reason}) when is_atom(operation) and is_atom(reason),
    do: {operation, reason}

  defp sanitized_reason(_reason), do: :filesystem_error

  defp realpath(path), do: PathSafety.realpath(path)

  defp error(code, message, context \\ %{}),
    do: {:error, Error.new(code, :bundle, message, context: context)}
end
