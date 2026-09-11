defmodule Backplane.SkillProtocol.Cache do
  @moduledoc "Verified exact-reference cache with explicit root ownership and offline state."

  alias Backplane.SkillProtocol.{
    Bundle,
    BundleManifest,
    Client,
    Error,
    Parser,
    PreparedSkill,
    SkillRef,
    Telemetry,
    Validator,
    Wire
  }

  alias Backplane.SkillProtocol.Cache.Ownership

  @default_max_bytes 512 * 1024 * 1024
  @state_version 1
  @block_codes %{
    "unauthorized" => :unauthorized,
    "forbidden" => :forbidden,
    "not_found" => :not_found,
    "revision_unavailable" => :revision_unavailable,
    "integrity_mismatch" => :integrity_mismatch
  }

  @enforce_keys [:root, :owner, :max_bytes, :clock, :cancelled?]
  defstruct [:root, :owner, :max_bytes, :clock, :cancelled?]

  @type t :: %__MODULE__{}

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(root, opts) when is_binary(root) do
    owner = Keyword.get(opts, :owner)

    with :ok <- nonempty(owner, "cache owner"),
         root = Path.expand(root),
         :ok <- File.mkdir_p(root),
         {:ok, root} <- Ownership.canonical_root(root),
         :ok <- Ownership.acquire(root, owner) do
      {:ok,
       %__MODULE__{
         root: root,
         owner: owner,
         max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
         clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
         cancelled?: Keyword.get(opts, :cancelled?, fn -> false end)
       }}
    else
      {:error, %Error{} = reason} ->
        {:error, reason}

      {:error, :busy} ->
        error(:invalid_request, "cache root is owned by another OS process")

      {:error, :different_owner} ->
        error(:invalid_request, "cache root is owned by another consumer")

      {:error, :legacy_process_owner} ->
        error(:invalid_request, "legacy cache ownership requires quiescent migration")

      {:error, {:legacy_process_owner, reason}} ->
        error(:invalid_request, "legacy cache ownership cannot be inspected", %{reason: reason})

      {:error, :unavailable} ->
        error(:temporarily_unavailable, "cache ownership backend is unavailable")

      {:error, :invalid_path} ->
        error(:invalid_request, "cache ownership lock path is invalid")

      {:error, reason} ->
        error(:invalid_request, "cache root cannot be initialized", %{reason: inspect(reason)})
    end
  end

  def new(_root, _opts), do: error(:invalid_request, "cache root is invalid")

  @spec new!(String.t(), keyword()) :: t()
  def new!(root, opts) do
    case new(root, opts) do
      {:ok, cache} -> cache
      {:error, reason} -> raise ArgumentError, reason.message
    end
  end

  @spec install(t(), Client.t(), BundleManifest.t(), binary()) ::
          {:ok, PreparedSkill.t()} | {:error, Error.t()}
  def install(%__MODULE__{} = cache, %Client{} = client, %BundleManifest{} = manifest, bytes)
      when is_binary(bytes) do
    started_at = Telemetry.start()

    {result, cache_outcome} =
      case locked(cache, fn -> install_locked(cache, client, manifest, bytes) end) do
        {:cache_result, outcome, result} -> {result, outcome}
        :aborted -> {error(:invalid_request, "cache lock was aborted"), :error}
      end

    Telemetry.emit(:cache, :install, result, started_at,
      metadata: reference_metadata(client, manifest.ref, cache_outcome),
      measurements: %{artifact_bytes: byte_size(bytes), prepared_bytes: manifest.unpacked_bytes}
    )
  end

  @spec offline(t(), Client.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, PreparedSkill.t()} | {:error, Error.t()}
  def offline(%__MODULE__{} = cache, %Client{} = client, skill_id, revision, max_age_ms)
      when is_binary(skill_id) and is_binary(revision) and is_integer(max_age_ms) and
             max_age_ms >= 0 do
    started_at = Telemetry.start()

    result =
      with :ok <- cancelled(cache),
           :ok <- no_block(cache, client, skill_id, revision),
           {:ok, association} <- association(cache, client, skill_id, revision),
           :ok <- fresh(cache, association, max_age_ms),
           {:ok, prepared} <- verify_association(cache, association) do
        {:ok, prepared}
      else
        {:error, %Error{code: :integrity_mismatch} = reason} ->
          _ = record_block(cache, client, skill_id, revision, :integrity_mismatch)
          {:error, reason}

        {:error, %Error{} = reason} ->
          {:error, reason}
      end

    cache_outcome = if match?({:ok, _prepared}, result), do: :offline_hit, else: :error

    Telemetry.emit(:cache, :offline, result, started_at,
      metadata: %{
        source_id: client.source_id,
        skill_id: skill_id,
        revision: revision,
        cache_outcome: cache_outcome
      }
    )
  end

  def offline(%__MODULE__{}, %Client{}, _skill_id, _revision, _max_age_ms),
    do: error(:invalid_request, "offline lookup requires an exact reference and nonnegative age")

  @spec record_block(t(), Client.t(), String.t(), String.t(), atom()) :: :ok | {:error, Error.t()}
  def record_block(cache, client, skill_id, revision, code)
      when code in [
             :unauthorized,
             :forbidden,
             :not_found,
             :revision_unavailable,
             :integrity_mismatch
           ] do
    payload = %{
      "version" => @state_version,
      "source_id" => client.source_id,
      "access_context_id" => client.access_context_id,
      "skill_id" => skill_id,
      "revision" => revision,
      "code" => Atom.to_string(code),
      "observed_at_ms" => cache.clock.()
    }

    atomic_json(block_path(cache, client, skill_id, revision), payload)
  end

  @spec cleanup(t()) :: :ok | {:error, Error.t()}
  def cleanup(%__MODULE__{} = cache) do
    locked(cache, fn ->
      with :ok <- cancelled(cache),
           {:ok, _removed} <- File.rm_rf(staging_root(cache)),
           :ok <- File.mkdir_p(staging_root(cache)) do
        :ok
      else
        {:error, %Error{} = reason} ->
          {:error, reason}

        {:error, reason, _path} ->
          error(:invalid_request, "cache staging cleanup failed", %{reason: inspect(reason)})

        {:error, reason} ->
          error(:invalid_request, "cache staging cleanup failed", %{reason: inspect(reason)})
      end
    end)
  end

  defp install_locked(cache, client, manifest, bytes) do
    with :ok <- cancelled(cache),
         :ok <- exact_manifest(client, manifest),
         :ok <- exact_digest(manifest.artifact_digest, bytes),
         {:miss, _reason} <- existing(cache, client, manifest),
         :ok <- capacity(cache, byte_size(bytes) + manifest.unpacked_bytes),
         {:ok, archive_stage} <- stage_archive(cache, bytes),
         result <- inspect_prepare_publish(cache, client, manifest, archive_stage) do
      case result do
        {:ok, _prepared} -> {:cache_result, :installed, result}
        {:error, %Error{}} -> {:cache_result, :error, result}
      end
    else
      {:ok, prepared} ->
        result =
          with :ok <- clear_block(cache, client, manifest.ref.skill_id, manifest.ref.revision),
               do: {:ok, prepared}

        outcome = if match?({:ok, _prepared}, result), do: :hit, else: :error
        {:cache_result, outcome, result}

      {:error, %Error{} = reason} ->
        if reason.code == :integrity_mismatch do
          _ =
            record_block(
              cache,
              client,
              manifest.ref.skill_id,
              manifest.ref.revision,
              :integrity_mismatch
            )
        end

        {:cache_result, :error, {:error, reason}}
    end
  end

  defp existing(cache, client, manifest) do
    path = association_path(cache, client, manifest.ref)

    with true <- File.regular?(path),
         {:ok, association} <- read_json(path),
         {:ok, prepared} <- verify_association(cache, association) do
      {:ok, prepared}
    else
      false -> {:miss, :not_cached}
      {:error, reason} -> {:miss, reason}
    end
  end

  defp inspect_prepare_publish(cache, client, manifest, archive_stage) do
    install_id = unique_id()

    prepared_path =
      Path.join([
        cache.root,
        "prepared",
        association_id(client, manifest.ref) <> "." <> install_id
      ])

    artifact_path =
      Path.join([
        cache.root,
        "artifacts",
        digest_hex(manifest.artifact_digest) <> "." <> install_id <> ".tar.gz"
      ])

    association_path = association_path(cache, client, manifest.ref)
    association_before = File.read(association_path)

    result =
      try do
        with {:ok, bundle} <-
               Bundle.inspect(archive_stage,
                 ref: manifest.ref,
                 cancelled?: cache.cancelled?,
                 supported_capabilities: manifest.required_capabilities
               ),
             :ok <- same_manifest(bundle.manifest, manifest),
             :ok <- cancelled(cache),
             {:ok, prepared} <-
               Bundle.prepare(bundle, prepared_path, cancelled?: cache.cancelled?),
             :ok <- File.rename(archive_stage, artifact_path),
             association = association_map(cache, client, manifest, artifact_path, prepared_path),
             :ok <- atomic_json(association_path, association),
             :ok <- clear_block(cache, client, manifest.ref.skill_id, manifest.ref.revision) do
          {:ok, prepared}
        else
          {:error, %Error{} = reason} ->
            {:error, reason}

          {:error, reason} ->
            error(:invalid_bundle, "cache installation failed", %{reason: inspect(reason)})
        end
      after
        File.rm(archive_stage)
      end

    case result do
      {:ok, _prepared} ->
        result

      {:error, _reason} ->
        rollback_install(prepared_path, artifact_path, association_path, association_before)
        result
    end
  end

  defp rollback_install(prepared_path, artifact_path, association_path, association_before) do
    File.rm_rf(prepared_path)
    File.rm(artifact_path)

    case association_before do
      {:ok, bytes} -> atomic_bytes(association_path, bytes)
      {:error, :enoent} -> File.rm(association_path)
      {:error, _reason} -> :ok
    end

    :ok
  end

  defp association(cache, client, skill_id, revision) do
    pattern = Path.join([cache.root, "associations", "*.json"])

    pattern
    |> Path.wildcard()
    |> Enum.reduce_while({:error, not_cached()}, fn path, _acc ->
      case read_json(path) do
        {:ok,
         %{
           "source_id" => source,
           "access_context_id" => context,
           "skill_id" => skill,
           "revision" => rev
         } = association}
        when source == client.source_id and context == client.access_context_id and
               skill == skill_id and rev == revision ->
          {:halt, {:ok, association}}

        _ ->
          {:cont, {:error, not_cached()}}
      end
    end)
  end

  defp verify_association(cache, association) do
    with %{
           "source_id" => source_id,
           "manifest" => manifest_map,
           "artifact_path" => artifact_relative,
           "prepared_path" => prepared_relative
         } <- association,
         {:ok, manifest} <- Wire.decode_manifest_map(manifest_map, source_id),
         artifact_path = Path.join(cache.root, artifact_relative),
         prepared_path = Path.join(cache.root, prepared_relative),
         :ok <- contained(cache.root, artifact_path),
         :ok <- contained(cache.root, prepared_path),
         {:ok, artifact} <- File.read(artifact_path),
         :ok <- exact_digest(manifest.artifact_digest, artifact),
         :ok <- verify_files(prepared_path, manifest.files),
         {:ok, document_bytes} <- File.read(Path.join(prepared_path, manifest.entrypoint)),
         {:ok, document} <- Parser.parse(document_bytes),
         {:ok, document} <-
           Validator.validate(document, supported_capabilities: manifest.required_capabilities) do
      {:ok, %PreparedSkill{root: prepared_path, document: document, manifest: manifest}}
    else
      {:error, %Error{} = reason} -> {:error, as_integrity(reason)}
      _ -> error(:integrity_mismatch, "cached association is malformed or incomplete")
    end
  end

  defp verify_files(root, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      path = Path.join(root, file.path)

      with :ok <- contained(root, path),
           {:ok, %{type: :regular, size: size}} <- File.lstat(path),
           true <- size == file.bytes,
           {:ok, bytes} <- File.read(path),
           true <- sha256(bytes) == file.sha256 do
        {:cont, :ok}
      else
        _ ->
          {:halt,
           error(:integrity_mismatch, "cached prepared resource failed verification", %{
             path: file.path
           })}
      end
    end)
  end

  defp exact_manifest(client, %{ref: %SkillRef{} = ref} = manifest) do
    cond do
      ref.source_id != client.source_id ->
        error(:integrity_mismatch, "manifest source does not match client")

      not is_binary(ref.skill_id) or not is_binary(ref.revision) ->
        error(:invalid_request, "manifest is not exact")

      ref.artifact_digest != manifest.artifact_digest ->
        error(:integrity_mismatch, "manifest digest association is invalid")

      true ->
        :ok
    end
  end

  defp exact_manifest(_client, _manifest), do: error(:invalid_request, "manifest is not exact")

  defp exact_digest(expected, bytes) do
    if Bundle.artifact_digest(bytes) == expected,
      do: :ok,
      else: error(:integrity_mismatch, "artifact digest does not match manifest")
  end

  defp same_manifest(left, right) do
    if Wire.manifest_map(left) == Wire.manifest_map(right),
      do: :ok,
      else: error(:integrity_mismatch, "artifact contents do not match resolved manifest")
  end

  defp association_map(cache, client, manifest, artifact_path, prepared_path) do
    %{
      "version" => @state_version,
      "source_id" => client.source_id,
      "access_context_id" => client.access_context_id,
      "skill_id" => manifest.ref.skill_id,
      "revision" => manifest.ref.revision,
      "artifact_digest" => manifest.artifact_digest,
      "verified_at_ms" => cache.clock.(),
      "manifest" => Wire.manifest_map(manifest),
      "artifact_path" => Path.relative_to(artifact_path, cache.root),
      "prepared_path" => Path.relative_to(prepared_path, cache.root)
    }
  end

  defp no_block(cache, client, skill_id, revision) do
    case read_json(block_path(cache, client, skill_id, revision)) do
      {:ok, %{"code" => code}} ->
        atom = Map.get(@block_codes, code, :integrity_mismatch)
        error(atom, "cached offline use is blocked by a known remote or integrity state")

      {:error, :enoent} ->
        :ok

      {:error, %Error{} = reason} ->
        {:error, reason}

      _ ->
        error(:integrity_mismatch, "cached block state is malformed")
    end
  end

  defp clear_block(cache, client, skill_id, revision) do
    case File.rm(block_path(cache, client, skill_id, revision)) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        error(:invalid_request, "cache block state cannot be cleared", %{reason: inspect(reason)})
    end
  end

  defp fresh(cache, %{"verified_at_ms" => verified}, max_age) when is_integer(verified) do
    if cache.clock.() - verified <= max_age,
      do: :ok,
      else: error(:not_found, "cached exact revision is expired")
  end

  defp fresh(_cache, _association, _max_age),
    do: error(:not_found, "cached exact revision is expired")

  defp capacity(cache, reservation) do
    used = directory_bytes(cache.root)

    if used + reservation <= cache.max_bytes,
      do: :ok,
      else:
        error(:capacity_exceeded, "cache capacity is exhausted", %{
          used: used,
          reservation: reservation,
          limit: cache.max_bytes
        })
  end

  defp directory_bytes(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(0, fn path, total ->
      case File.lstat(path) do
        {:ok, %{type: :regular, size: size}} -> total + size
        _ -> total
      end
    end)
  end

  defp stage_archive(cache, bytes) do
    path = Path.join(staging_root(cache), unique_id() <> ".tar.gz")

    case File.write(path, bytes, [:binary, :exclusive]) do
      :ok ->
        {:ok, path}

      {:error, reason} ->
        error(:invalid_bundle, "artifact staging failed", %{reason: inspect(reason)})
    end
  end

  defp atomic_json(path, value) do
    atomic_bytes(path, JSON.encode!(value))
  end

  defp atomic_bytes(path, bytes) do
    temporary = path <> ".tmp." <> unique_id()

    try do
      with :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
           {:ok, io} <- File.open(temporary, [:read, :write, :binary]),
           :ok <- :file.sync(io),
           :ok <- File.close(io),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} ->
          error(:invalid_request, "cache metadata cannot be persisted", %{reason: inspect(reason)})
      end
    after
      File.rm(temporary)
    end
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- JSON.decode(bytes) do
      {:ok, value}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> error(:integrity_mismatch, "cached metadata is malformed")
    end
  end

  defp locked(cache, fun),
    do: :global.trans({{__MODULE__, cache.root}, self()}, fun)

  defp cancelled(cache) do
    if cache.cancelled?.(),
      do: error(:cancelled, "cache operation was cancelled"),
      else: :ok
  end

  defp contained(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)

    if path == root or String.starts_with?(path, root <> "/"),
      do: :ok,
      else: error(:integrity_mismatch, "cached path escapes cache root")
  end

  defp association_path(cache, client, ref),
    do: Path.join([cache.root, "associations", association_id(client, ref) <> ".json"])

  defp association_id(client, ref),
    do:
      id([
        client.source_id,
        client.access_context_id,
        ref.skill_id,
        ref.revision,
        ref.artifact_digest
      ])

  defp block_path(cache, client, skill_id, revision),
    do:
      Path.join([
        cache.root,
        "blocks",
        id([client.source_id, client.access_context_id, skill_id, revision]) <> ".json"
      ])

  defp reference_metadata(client, ref, cache_outcome) do
    %{
      source_id: client.source_id,
      skill_id: ref.skill_id,
      revision: ref.revision,
      artifact_digest: ref.artifact_digest,
      cache_outcome: cache_outcome
    }
  end

  defp id(parts), do: parts |> :erlang.term_to_binary() |> sha256()
  defp digest_hex("sha256:" <> digest), do: digest
  defp staging_root(cache), do: Path.join(cache.root, ".staging")
  defp unique_id, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp as_integrity(%Error{code: :integrity_mismatch} = reason), do: reason

  defp as_integrity(_reason),
    do: Error.new(:integrity_mismatch, :cache, "cached entry failed verification")

  defp not_cached, do: Error.new(:not_found, :cache, "exact revision is not cached")

  defp nonempty(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty(_value, field), do: error(:invalid_request, field <> " must be a nonempty string")

  defp error(code, message, context \\ %{}),
    do: {:error, Error.new(code, :cache, message, context: context)}
end
