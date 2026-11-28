defmodule Backplane.SkillProtocol.Source.Local do
  @moduledoc "Bounded local discovery under explicit host-approved roots."

  alias Backplane.SkillProtocol.{
    Bundle,
    Catalog,
    Descriptor,
    Diagnostic,
    Error,
    Parser,
    PathSafety,
    SkillRef,
    Telemetry,
    Validator
  }

  @defaults [
    max_depth: 16,
    max_entries: 10_000,
    max_diagnostics: 100,
    profile: :legacy,
    supported_capabilities: [],
    missing: :error
  ]

  @spec discover([map() | keyword()], keyword()) :: {:ok, [Descriptor.t()]} | {:error, Error.t()}
  def discover(roots, opts \\ []) when is_list(roots) do
    case discover_with_diagnostics(roots, opts) do
      {:ok, descriptors, _diagnostics} -> {:ok, descriptors}
      {:error, _} = error -> error
    end
  end

  @spec discover_with_diagnostics([map() | keyword()], keyword()) ::
          {:ok, [Descriptor.t()], [Diagnostic.t()]} | {:error, Error.t()}
  def discover_with_diagnostics(roots, opts \\ []) when is_list(roots) do
    opts = Keyword.take(opts, [:max_depth, :max_entries, :max_diagnostics])

    with {:ok, opts} <- index_options(opts) do
      Enum.reduce_while(roots, {:ok, [], [], 0}, fn root, {:ok, entries, diagnostics, count} ->
        case discover_root(root, opts, count, length(diagnostics)) do
          {:ok, descriptors, skipped, visited} ->
            {:cont, {:ok, descriptors ++ entries, skipped ++ diagnostics, count + visited}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, descriptors, diagnostics, _} ->
          {:ok, Catalog.sort(descriptors), sort_diagnostics(diagnostics)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp discover_root(root, opts, count, diagnostic_count) do
    id = value(root, :source_id)
    path = value(root, :path)
    precedence = value(root, :precedence, 100)
    opts = %{opts | max_entries: opts.max_entries - count}

    if is_binary(id) and id != "" and is_binary(path) do
      with {:ok, inventory} <- inventory(path, opts) do
        records = load(inventory, id, opts, %{}, MapSet.new(), false)

        {descriptors, diagnostics} =
          project(records, opts.max_diagnostics - diagnostic_count, :one_shot)

        descriptors = Enum.map(descriptors, &%{&1 | precedence: precedence})
        {:ok, descriptors, diagnostics, inventory.count}
      end
    else
      {:error, Error.new(:invalid_request, :discovery, "root requires source_id and path")}
    end
  end

  @doc false
  def index_options(opts) do
    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- Keyword.keys(@defaults) == [],
         options = Map.merge(Map.new(@defaults), Map.new(opts)),
         :ok <- valid_limit(options.max_depth, :max_depth),
         :ok <- valid_limit(options.max_entries, :max_entries),
         :ok <- valid_limit(options.max_diagnostics, :max_diagnostics),
         true <- options.profile in [:standard, :legacy],
         true <- options.missing in [:empty, :error],
         true <- is_list(options.supported_capabilities) do
      {:ok, options}
    else
      {:error, _} = error -> error
      false -> {:error, Error.new(:invalid_request, :discovery, "invalid local index options")}
    end
  end

  @doc false
  def index(path, id, opts, previous, {paths, audit?}, before_scan) do
    started_at = Telemetry.start()
    scanned = inventory(path, opts, before_scan)

    with {:ok, scanned} <-
           Telemetry.emit(:directory, :scan, scanned, started_at, metadata: %{source_id: id}) do
      records = load(scanned, id, opts, previous || %{}, paths, audit?)
      verify_index(path, opts, scanned, records, records != previous)
    end
  end

  defp verify_index(path, opts, scanned, records, true) do
    # A write or rename can land after visiting a directory or while parsing.
    # Retain work for observations that still match and reconcile before publishing.
    case inventory(path, opts) do
      {:ok, ^scanned} -> index_view(opts, records)
      {:ok, _changed} -> {:retry, records}
      {:error, _} = error -> error
    end
  end

  defp verify_index(_path, opts, _scanned, records, false), do: index_view(opts, records)

  defp index_view(opts, records) do
    {descriptors, diagnostics} = project(records, opts.max_diagnostics, :directory)
    {:ok, %{records: records, descriptors: descriptors, diagnostics: diagnostics}}
  end

  defp inventory(path, opts, before_scan \\ fn _root -> :ok end) do
    case root_identity(path) do
      {:ok, {root, _, _} = identity} ->
        with :ok <- before_scan.(identity),
             {:ok, _seen, files, count} <-
               walk(root, root, {0, opts.max_depth}, opts.max_entries, {MapSet.new(), %{}, 0}) do
          {:ok, %{root: identity, files: files, count: count}}
        end

      :missing when opts.missing == :empty ->
        :ok = before_scan.(nil)
        {:ok, %{root: nil, files: %{}, count: 0}}

      :missing ->
        :ok = before_scan.(nil)
        unreadable("local root cannot be read", :enoent)

      {:error, _} = error ->
        :ok = before_scan.(nil)
        error
    end
  end

  defp root_identity(path) do
    with {:ok, _} <- File.lstat(path),
         {:ok, root} <- realpath(path),
         {:ok, %{type: :directory} = stat} <- File.stat(root, time: :posix) do
      {:ok, {root, stat.major_device, stat.inode}}
    else
      {:error, :enoent} -> :missing
      {:error, %Error{}} = error -> error
      {:error, reason} -> unreadable("local root cannot be read", reason)
      {:ok, _stat} -> unreadable("local root cannot be read", :enotdir)
    end
  end

  defp walk(_path, _root, {depth, max_depth}, _remaining, _state) when depth > max_depth,
    do: {:error, Error.new(:limit_exceeded, :discovery, "local scan depth limit exceeded")}

  defp walk(path, root, {depth, max_depth}, remaining, {seen, files, count}) do
    with :ok <- entry_budget(remaining - count),
         {:ok, canonical} <- realpath(path),
         :ok <- contained(canonical, root),
         false <- MapSet.member?(seen, canonical),
         {:ok, names} <- File.ls(canonical) do
      state = {MapSet.put(seen, canonical), files, count + 1}

      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, state}, fn name, {:ok, {visited, entries, total}} ->
        child = Path.join(canonical, name)

        case inspect_child(
               child,
               root,
               {depth + 1, max_depth},
               remaining,
               {visited, entries, total}
             ) do
          {:ok, next_seen, next_entries, next_total} ->
            {:cont, {:ok, {next_seen, next_entries, next_total}}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, {visited, entries, total}} -> {:ok, visited, entries, total}
        {:error, _} = error -> error
      end
    else
      true -> {:ok, seen, files, count + 1}
      {:error, %Error{}} = error -> error
      {:error, reason} -> unreadable("local root cannot be read", reason)
    end
  end

  defp inspect_child(path, root, depth, remaining, {seen, files, count} = state) do
    with :ok <- entry_budget(remaining - count) do
      cond do
        File.dir?(path) ->
          walk(path, root, depth, remaining, state)

        Path.basename(path) == "SKILL.md" ->
          with {:ok, canonical} <- realpath(path),
               :ok <- contained(canonical, root),
               {:ok, stat} <- File.stat(canonical, time: :posix) do
            stamp =
              {stat.type, stat.major_device, stat.inode, stat.size, stat.mode, stat.mtime,
               stat.ctime}

            {:ok, seen, Map.put(files, path, {canonical, stamp}), count + 1}
          else
            {:error, %Error{}} = error -> error
            {:error, reason} -> unreadable("local document cannot be inspected", reason)
          end

        true ->
          {:ok, seen, files, count + 1}
      end
    end
  end

  defp load(%{root: nil}, _id, _opts, _previous, _paths, _audit?), do: %{}

  defp load(%{root: {root, _, _}, files: files}, id, opts, previous, paths, audit?) do
    Map.new(files, fn {path, {canonical, stamp} = file} ->
      old = Map.get(previous, path)

      reread? =
        audit? or MapSet.member?(paths, path) or MapSet.member?(paths, canonical) or
          not match?(%{file: ^file}, old)

      record =
        case {reread?, stamp} do
          {false, _} ->
            old

          {true, {:regular, _, _, _, _, _, _}} ->
            read_record(path, file, root, id, opts, old)

          {true, _non_regular} ->
            skipped(path, file, root, :invalid_document)
        end

      {path, record}
    end)
  end

  defp read_record(path, {canonical, _stamp} = file, root, id, opts, old) do
    case File.read(canonical) do
      {:ok, bytes} ->
        digest = Bundle.artifact_digest(bytes)

        case old do
          %{digest: ^digest, file: {^canonical, _}} ->
            %{old | file: file}

          _ ->
            parse_record(bytes, path, file, root, id, opts)
            |> Map.put(:digest, digest)
        end

      {:error, _reason} ->
        skipped(path, file, root, :invalid_document)
    end
  end

  defp parse_record(bytes, path, {canonical, _stamp} = file, root, id, opts) do
    with {:ok, document} <- Parser.parse(bytes),
         {:ok, document} <-
           Validator.validate(document,
             profile: opts.profile,
             supported_capabilities: opts.supported_capabilities
           ) do
      relative_dir = canonical |> Path.dirname() |> Path.relative_to(root)
      skill_id = if relative_dir == ".", do: document.name, else: relative_dir

      descriptor = %Descriptor{
        ref: %SkillRef{source_id: id, skill_id: skill_id},
        name: document.name,
        description: document.description,
        argument_hint: argument_hint(document.metadata["argument-hint"]),
        disable_model_invocation: document.metadata["disable-model-invocation"] == true,
        user_invocable: Map.get(document.metadata, "user-invocable", true),
        path: canonical,
        precedence: 100,
        publication_status: :local
      }

      diagnostics =
        Enum.map(document.diagnostics, fn diagnostic ->
          %{
            diagnostic
            | context: Map.put(diagnostic.context, :path, Path.relative_to(path, root))
          }
        end)

      %{file: file, descriptor: descriptor, diagnostics: diagnostics}
    else
      {:error, %Error{} = error} ->
        skipped(path, file, root, error.code)
    end
  end

  defp argument_hint(hint) when is_binary(hint), do: hint
  defp argument_hint(_hint), do: nil

  defp skipped(path, file, root, code) do
    diagnostic =
      Diagnostic.new(code, :discovery, :warning, "skill document skipped", %{
        path: Path.relative_to(path, root),
        code: code
      })

    %{file: file, descriptor: nil, diagnostics: [diagnostic]}
  end

  defp project(records, limit, mode) do
    descriptors =
      for %{descriptor: %Descriptor{} = entry, digest: digest} <- Map.values(records),
          do: %{entry | document_digest: digest}

    diagnostics =
      records
      |> Map.values()
      |> Enum.filter(&(mode == :directory or is_nil(&1.descriptor)))
      |> Enum.flat_map(& &1.diagnostics)
      |> sort_diagnostics()
      |> Enum.take(limit)

    {Catalog.sort(descriptors), diagnostics}
  end

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn diagnostic ->
      {diagnostic.context.path, diagnostic.code, diagnostic.message}
    end)
  end

  defp entry_budget(remaining) when remaining > 0, do: :ok

  defp entry_budget(_remaining),
    do: {:error, Error.new(:limit_exceeded, :discovery, "local scan entry limit exceeded")}

  defp valid_limit(value, _name) when is_integer(value) and value >= 0, do: :ok

  defp valid_limit(_value, name),
    do:
      {:error, Error.new(:invalid_request, :discovery, "#{name} must be a non-negative integer")}

  defp realpath(path) do
    case PathSafety.realpath(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> unreadable("path cannot be resolved", reason)
    end
  end

  defp unreadable(message, reason) do
    {:error,
     Error.new(:invalid_request, :discovery, message,
       context: %{reason: inspect(reason)},
       retryable: true
     )}
  end

  defp contained(path, root) do
    if path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/") do
      :ok
    else
      {:error, Error.new(:invalid_request, :discovery, "linked path escapes approved root")}
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(list, key, default) when is_list(list), do: Keyword.get(list, key, default)
end
