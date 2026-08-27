defmodule Backplane.HostAgent.Memory.Import do
  @moduledoc """
  Safely imports host-local transcripts into the normal durable capture spool.

  Filesystem access, source parsing, privacy filtering, and source identity all stay on the
  host. Only canonical envelopes and non-sensitive fingerprints leave the machine.
  """

  alias Backplane.HostAgent.Memory.EventEnvelope
  alias Backplane.HostAgent.Memory.Spool.Turso, as: DefaultSpool

  @defaults [
    max_files: 1_000,
    max_entries: 100_000,
    max_bytes: 256 * 1024 * 1024,
    max_depth: 12,
    allow_symlinks: false
  ]

  @sensitive_segments ~w(.aws .azure .config/gcloud .env .gnupg .netrc .npmrc .ssh credentials credential id_ed25519 id_rsa secrets secret tokens token)
  @sensitive_sequences [[".config", "gcloud"]]
  @sensitive_extensions ~w(.key .pem .p12 .pfx)

  @doc "Imports a Claude Code JSONL file or directory beneath an explicitly approved root."
  def run(path, opts) when is_binary(path) and is_list(opts) do
    opts = Keyword.merge(@defaults, opts)

    with {:ok, root, target} <- authorize_path(path, opts),
         batch_id = Keyword.get_lazy(opts, :batch_id, &random_uuid/0),
         source_path_fingerprint = path_fingerprint(root, target),
         :ok <- report(opts, started_report(batch_id, source_path_fingerprint)) do
      run_started(target, root, batch_id, source_path_fingerprint, opts)
    end
  end

  def run(_path, _opts), do: {:error, :invalid_options}

  defp run_started(target, root, batch_id, source_path_fingerprint, opts) do
    result =
      with {:ok, files} <- discover_files(target, root, opts),
           {:ok, result} <- safe_import_files(files, root, opts) do
        {:ok, result}
      end

    case result do
      {:ok, result} ->
        status =
          if result.imported_count == 0 and result.duplicate_count > 0,
            do: :unchanged,
            else: :imported

        result =
          Map.merge(result, %{
            batch_id: batch_id,
            status: status,
            integration: "claude_code",
            source_format: "claude_code_jsonl",
            source_path_fingerprint: source_path_fingerprint
          })

        case report(opts, completed_report(result)) do
          :ok -> {:ok, result}
          {:error, _reason} = error -> fail_started(opts, batch_id, error)
        end

      {:error, _reason} = error ->
        fail_started(opts, batch_id, error)
    end
  end

  defp authorize_path(path, opts) do
    roots = Keyword.get(opts, :approved_roots, [])
    target = Path.expand(path)

    with [_ | _] <- roots,
         {:ok, root} <- containing_root(target, roots),
         :ok <- reject_sensitive_path(target),
         :ok <- validate_path_components(target, root, opts) do
      {:ok, root, target}
    else
      [] -> {:error, :approved_roots_required}
      :error -> {:error, :outside_approved_roots}
      {:error, _reason} = error -> error
    end
  end

  defp containing_root(target, roots) do
    roots
    |> Enum.map(&Path.expand/1)
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.find(&within?(target, &1))
    |> case do
      nil -> :error
      root -> {:ok, root}
    end
  end

  defp within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp reject_sensitive_path(path) do
    segments = path |> Path.split() |> Enum.map(&String.downcase/1)

    sensitive? =
      sensitive_sequence?(segments) or
        Enum.any?(segments, fn segment ->
          segment in @sensitive_segments or
            Enum.any?(@sensitive_extensions, &String.ends_with?(segment, &1)) or
            Regex.match?(
              ~r/(^|[._-])(credential|secret|token|private[-_]?key)([._-]|$)/,
              segment
            )
        end)

    if sensitive?, do: {:error, :sensitive_path}, else: :ok
  end

  defp sensitive_sequence?(segments) do
    Enum.any?(@sensitive_sequences, fn sequence ->
      segments |> Enum.chunk_every(length(sequence), 1, :discard) |> Enum.member?(sequence)
    end)
  end

  defp validate_path_components(target, root, opts) do
    with :ok <- validate_component(root, root, opts) do
      target
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.reduce_while({:ok, root}, fn segment, {:ok, parent} ->
        candidate = Path.join(parent, segment)

        case validate_component(candidate, root, opts) do
          :ok -> {:cont, {:ok, candidate}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _path} -> :ok
        error -> error
      end
    end
  end

  defp validate_component(candidate, root, opts) do
    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        if opts[:allow_symlinks],
          do: validate_link_destination(candidate, root),
          else: {:error, :symlink_rejected}

      {:ok, _stat} ->
        :ok

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  defp validate_link_destination(path, root) do
    with {:ok, destination} <- File.read_link(path) do
      resolved = destination |> Path.expand(Path.dirname(path))

      if within?(resolved, root),
        do: reject_sensitive_path(resolved),
        else: {:error, :outside_approved_roots}
    else
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  defp discover_files(target, root, opts) do
    case walk(target, root, 0, [], 0, MapSet.new(), opts) do
      {:ok, files, _bytes} -> {:ok, Enum.sort(files)}
      {:error, _reason} = error -> error
    end
  end

  defp walk(path, root, depth, files, bytes, visited_links, opts) do
    if depth > opts[:max_depth] do
      {:error, :max_depth_exceeded}
    else
      with :ok <- reject_sensitive_path(path),
           {:ok, stat} <- File.lstat(path) do
        case stat.type do
          :regular -> add_file(path, stat, files, bytes, opts)
          :directory -> walk_directory(path, root, depth, files, bytes, visited_links, opts)
          :symlink -> walk_link(path, root, depth, files, bytes, visited_links, opts)
          _other -> {:ok, files, bytes}
        end
      else
        {:error, reason} -> {:error, {:file_error, reason}}
      end
    end
  end

  defp add_file(path, stat, files, bytes, opts) do
    cond do
      length(files) + 1 > opts[:max_files] -> {:error, :too_many_files}
      bytes + stat.size > opts[:max_bytes] -> {:error, :too_many_bytes}
      true -> {:ok, [{path, file_identity(stat)} | files], bytes + stat.size}
    end
  end

  defp walk_directory(path, root, depth, files, bytes, visited_links, opts) do
    with {:ok, names} <- File.ls(path) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, files, bytes}, fn name, {:ok, acc_files, acc_bytes} ->
        case walk(
               Path.join(path, name),
               root,
               depth + 1,
               acc_files,
               acc_bytes,
               visited_links,
               opts
             ) do
          {:ok, next_files, next_bytes} -> {:cont, {:ok, next_files, next_bytes}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  defp walk_link(path, root, depth, files, bytes, visited_links, opts) do
    cond do
      not opts[:allow_symlinks] ->
        {:error, :symlink_rejected}

      MapSet.member?(visited_links, path) ->
        {:error, :symlink_cycle}

      true ->
        with :ok <- validate_link_destination(path, root),
             {:ok, destination} <- File.read_link(path) do
          walk(
            Path.expand(destination, Path.dirname(path)),
            root,
            depth + 1,
            files,
            bytes,
            MapSet.put(visited_links, path),
            opts
          )
        end
    end
  end

  defp import_files(files, root, opts) do
    initial = %{
      discovered_count: 0,
      imported_count: 0,
      duplicate_count: 0,
      rejected_count: 0,
      sequences: %{}
    }

    files
    |> Enum.reduce_while({:ok, initial}, fn file, {:ok, acc} ->
      case import_file(file, root, acc, opts) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Map.delete(result, :sequences)}
      error -> error
    end
  end

  defp safe_import_files(files, root, opts) do
    import_files(files, root, opts)
  rescue
    error -> {:error, {:import_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:import_failure, kind}}
  end

  defp import_file({file, expected_identity}, root, initial, opts) do
    with :ok <- before_file_open(file, opts),
         {:ok, stat} <- File.lstat(file),
         :ok <- validate_open_candidate(stat, expected_identity),
         {:ok, result} <- open_and_import(file, expected_identity, root, initial, opts) do
      {:ok, result}
    else
      {:error, %File.Error{reason: reason}} -> {:error, {:file_error, reason}}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} = error -> error
    end
  end

  defp open_and_import(file, expected_identity, root, initial, opts) do
    case File.open(file, [:read], fn io ->
           with :ok <- validate_open_file(io, expected_identity) do
             import_lines(IO.stream(io, :line), file, root, initial, opts)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  defp import_lines(lines, file, root, initial, opts) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, initial}, fn {line, line_number}, {:ok, acc} ->
      discovered = acc.discovered_count + 1

      if discovered > opts[:max_entries] do
        {:halt, {:error, :too_many_entries}}
      else
        acc = %{acc | discovered_count: discovered}

        case parse_line(line, file, root, line_number, acc, opts) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:skip, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
  end

  defp before_file_open(file, opts) do
    case Keyword.get(opts, :before_file_open) do
      hook when is_function(hook, 1) -> hook.(file)
      _other -> :ok
    end
  end

  defp validate_open_candidate(%File.Stat{type: :regular} = stat, expected_identity) do
    if file_identity(stat) == expected_identity, do: :ok, else: {:error, :file_changed}
  end

  defp validate_open_candidate(_stat, _expected_identity), do: {:error, :file_changed}

  defp validate_open_file(io, expected_identity) do
    case :file.read_file_info(io) do
      {:ok, info} ->
        identity = {elem(info, 9), elem(info, 10), elem(info, 11), elem(info, 2)}
        if identity == expected_identity, do: :ok, else: {:error, :file_changed}

      {:error, _reason} ->
        {:error, :file_changed}
    end
  end

  defp file_identity(%File.Stat{} = stat) do
    {stat.major_device, stat.minor_device, stat.inode, stat.type}
  end

  defp parse_line(line, file, root, line_number, acc, opts) do
    with {:ok, source} when is_map(source) <- Jason.decode(line),
         {:ok, event_type} <- event_type(source),
         {:ok, session_id} <- source_session(source),
         {:ok, occurred_at} <- occurred_at(source) do
      sequence = Map.get(acc.sequences, session_id, 0) + 1
      fingerprint = record_fingerprint(source, Path.relative_to(file, root), line_number)
      payload = source_payload(source, fingerprint)
      idempotency_key = "claude_code_jsonl:" <> fingerprint

      envelope = %{
        schema_version: 1,
        event_id: deterministic_uuid(idempotency_key),
        host_id: Keyword.fetch!(opts, :host_id),
        agent_id: Keyword.get(opts, :agent_id, "claude_code"),
        client_id: "claude_code",
        integration: "claude_code_import",
        project: source["cwd"],
        scope: if(is_binary(source["cwd"]), do: "project:" <> source["cwd"], else: nil),
        session_id: session_id,
        sequence: sequence,
        event_type: event_type,
        occurred_at: occurred_at,
        idempotency_key: idempotency_key,
        payload_hash: EventEnvelope.payload_hash(payload),
        privacy: %{"filtered" => false, "filter_version" => "pending", "redaction_count" => 0},
        payload: payload
      }

      with {:ok, envelope} <-
             EventEnvelope.build(Map.reject(envelope, fn {_key, value} -> is_nil(value) end)) do
        case spool_module(opts).append(Keyword.get(opts, :spool), envelope) do
          {:ok, _stored} ->
            {:ok,
             %{
               acc
               | imported_count: acc.imported_count + 1,
                 sequences: Map.put(acc.sequences, session_id, sequence)
             }}

          {:duplicate, _stored} ->
            {:ok,
             %{
               acc
               | duplicate_count: acc.duplicate_count + 1,
                 sequences: Map.put(acc.sequences, session_id, sequence)
             }}

          {:error, reason} ->
            {:error, {:spool_error, reason}}
        end
      end
    else
      _reason -> {:skip, %{acc | rejected_count: acc.rejected_count + 1}}
    end
  end

  defp event_type(%{"type" => "user"}), do: {:ok, "conversation.user_message"}
  defp event_type(%{"type" => "assistant"}), do: {:ok, "conversation.agent_message"}
  defp event_type(_source), do: {:error, :unsupported_record}

  defp source_session(source) do
    case source["sessionId"] || source["session_id"] do
      value when is_binary(value) ->
        if(String.trim(value) == "", do: {:error, :session_id}, else: {:ok, value})

      _value ->
        {:error, :session_id}
    end
  end

  defp occurred_at(%{"timestamp" => timestamp}) when is_binary(timestamp) do
    if match?({:ok, _, _}, DateTime.from_iso8601(timestamp)),
      do: {:ok, timestamp},
      else: {:error, :timestamp}
  end

  defp occurred_at(_source), do: {:ok, "1970-01-01T00:00:00Z"}

  defp source_payload(source, fingerprint) do
    %{
      "message" => Map.get(source, "message", %{}),
      "source" => %{"format" => "claude_code_jsonl", "fingerprint" => fingerprint}
    }
  end

  defp record_fingerprint(source, relative_path, line_number) do
    stable_source =
      case source["uuid"] do
        uuid when is_binary(uuid) and uuid != "" -> "uuid:" <> uuid
        _ -> "line:#{relative_path}:#{line_number}:#{EventEnvelope.payload_hash(source)}"
      end

    digest(stable_source)
  end

  defp path_fingerprint(root, target),
    do: "sha256:" <> digest(root <> "\0" <> Path.relative_to(target, root))

  defp started_report(batch_id, fingerprint) do
    %{
      "protocol" => "host_import.v1",
      "action" => "started",
      "batch_id" => batch_id,
      "integration" => "claude_code",
      "source_format" => "claude_code_jsonl",
      "source_path_fingerprint" => fingerprint
    }
  end

  defp completed_report(result) do
    result
    |> Map.take([
      :batch_id,
      :discovered_count,
      :imported_count,
      :duplicate_count,
      :rejected_count
    ])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.merge(%{"protocol" => "host_import.v1", "action" => "completed"})
  end

  defp failed_report(batch_id, reason) do
    %{
      "protocol" => "host_import.v1",
      "action" => "failed",
      "batch_id" => batch_id,
      "discovered_count" => 0,
      "imported_count" => 0,
      "duplicate_count" => 0,
      "rejected_count" => 0,
      "error" => safe_error(reason)
    }
  end

  defp fail_started(opts, batch_id, {:error, reason} = error) do
    _ = report(opts, failed_report(batch_id, reason))
    error
  end

  defp safe_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error(_reason), do: "import_failed"

  defp report(opts, payload) do
    case Keyword.get(opts, :reporter) do
      nil -> :ok
      reporter when is_function(reporter, 1) -> safe_report(reporter, payload)
    end
  end

  defp safe_report(reporter, payload) do
    case reporter.(payload) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_reporter_reply}
    end
  rescue
    error -> {:error, {:reporter_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:reporter_failure, kind}}
  end

  defp digest(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp deterministic_uuid(value) do
    <<prefix::binary-size(6), _::4, version_tail::12, _::2, variant_tail::62, _::binary>> =
      :crypto.hash(:sha256, value)

    <<prefix::binary, 5::4, version_tail::12, 2::2, variant_tail::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
                 e::binary-size(12)>> ->
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp random_uuid do
    deterministic_uuid(:crypto.strong_rand_bytes(32))
  end

  defp spool_module(opts), do: Keyword.get(opts, :spool_module, DefaultSpool)
end
