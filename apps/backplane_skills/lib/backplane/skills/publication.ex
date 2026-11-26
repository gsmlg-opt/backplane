defmodule Backplane.Skills.Publication do
  @moduledoc "Publishes and resolves immutable Skill Protocol revisions."

  import Ecto.Query

  alias Backplane.Repo
  alias Backplane.SkillProtocol.{Bundle, BundleManifest, Error, SkillRef, Wire}
  alias Backplane.Skills.{Blob, Revision, Skill}

  @source_id "backplane"

  @spec inspect_archive(String.t(), String.t()) :: {:ok, Bundle.t()} | {:error, Error.t()}
  def inspect_archive(path, skill_id) do
    Bundle.inspect(path,
      validation_profile: :standard,
      ref: %SkillRef{source_id: @source_id, skill_id: skill_id}
    )
  end

  @spec commit(Skill.t(), Bundle.t(), String.t()) :: {:ok, Skill.t()} | {:error, term()}
  def commit(%Skill{} = skill, %Bundle{} = bundle, blob_ref) when is_binary(blob_ref) do
    manifest = manifest_map(bundle.manifest, skill.id)
    revision = revision_for(bundle.manifest.artifact_digest)
    now = DateTime.utc_now()

    attrs = %{
      skill_id: skill.id,
      revision: revision,
      artifact_digest: bundle.manifest.artifact_digest,
      manifest: manifest,
      blob_ref: blob_ref,
      published_at: now
    }

    case Repo.insert(Revision.changeset(%Revision{}, attrs),
           on_conflict: :nothing,
           conflict_target: [:skill_id, :revision]
         ) do
      {:ok, _revision} ->
        skill
        |> Skill.publication_changeset(%{
          current_revision: revision,
          publication_status: "ready",
          publication_diagnostic: %{}
        })
        |> Repo.update()

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec mark_invalid(Skill.t(), term()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def mark_invalid(%Skill{} = skill, reason) do
    skill
    |> Skill.publication_changeset(%{
      publication_status: "invalid",
      publication_diagnostic: diagnostic(reason)
    })
    |> Repo.update()
  end

  @spec publish_existing(Skill.t(), String.t(), keyword()) ::
          {:ok, Revision.t()} | {:error, term()}
  def publish_existing(%Skill{} = skill, archive_path, opts \\ []) do
    blob_opts = Keyword.get(opts, :blob, [])

    with {:ok, bundle} <- inspect_archive(archive_path, skill.id),
         {:ok, blob_ref} <- Blob.put_file(archive_path, blob_opts),
         {:ok, published} <- publish_locked(skill.id, bundle, blob_ref) do
      {:ok, Repo.get_by!(Revision, skill_id: published.id, revision: published.current_revision)}
    end
  end

  @spec publish_generated(map(), keyword()) :: {:ok, Skill.t()} | {:error, term()}
  def publish_generated(attrs, opts \\ []) when is_map(attrs) do
    blob_opts = Keyword.get(opts, :blob, [])

    with_generated_bundle(
      attrs,
      fetch(attrs, :slug),
      fn bundle ->
        with {:ok, blob_ref} <- Blob.put_file(bundle.archive_path, blob_opts) do
          publish_generated_locked(attrs, bundle, blob_ref)
        end
      end,
      &record_generated_invalid(attrs, &1)
    )
  end

  @doc "Publish the database skill held by the caller's save transaction."
  def publish_database(%Skill{} = skill) do
    name = if valid_name?(skill.name), do: skill.name, else: skill.slug

    with_generated_bundle(
      skill,
      name,
      fn bundle ->
        with {:ok, blob_ref} <- Blob.put_file(bundle.archive_path),
             {:ok, saved} <-
               skill |> Ecto.Changeset.change(archive_ref: blob_ref) |> Repo.update() do
          commit(saved, bundle, blob_ref)
        end
      end,
      &mark_invalid(skill, &1)
    )
  end

  defp valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/, name)

  @doc "Publish a verified, complete GitHub skill bundle without changing operator selections."
  def publish_github(attrs, bundle) do
    with {:ok, blob_ref} <- Blob.put_file(bundle.archive_path) do
      publish_generated_locked(attrs, bundle, blob_ref)
    end
  end

  @spec resolve(String.t(), String.t() | nil) :: {:ok, Revision.t()} | {:error, atom()}
  def resolve(skill_id, revision \\ nil)

  def resolve(skill_id, revision)
      when is_binary(skill_id) and (is_nil(revision) or (is_binary(revision) and revision != "")) do
    query =
      from(r in Revision,
        join: s in Skill,
        on: s.id == r.skill_id,
        where: s.id == ^skill_id and s.enabled == true
      )

    query =
      if is_binary(revision) and revision != "" do
        where(query, [r, _s], r.revision == ^revision)
      else
        where(query, [r, s], r.revision == s.current_revision)
      end

    case Repo.one(query) do
      nil -> {:error, if(is_binary(revision), do: :revision_unavailable, else: :not_found)}
      %Revision{} = published -> {:ok, published}
    end
  end

  def resolve(_skill_id, _revision), do: {:error, :invalid_request}

  @spec artifact(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def artifact(skill_id, revision, opts \\ []) do
    with {:ok, %Revision{} = published} <- resolve(skill_id, revision),
         {:ok, stream} <- Blob.get(published.blob_ref, Keyword.get(opts, :blob, [])),
         bytes <- Enum.into(stream, <<>>),
         true <- Bundle.artifact_digest(bytes) == published.artifact_digest do
      {:ok, bytes}
    else
      false -> {:error, :integrity_mismatch}
      {:error, _} = error -> error
    end
  end

  @spec catalog(keyword()) :: %{data: [map()], next_cursor: String.t() | nil}
  def catalog(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> min(100) |> max(1)
    after_id = Keyword.get(opts, :after)
    fields = discovery_fields(opts[:view], Keyword.get(opts, :fields, []))

    query =
      from(s in Skill,
        join: r in Revision,
        on: r.skill_id == s.id and r.revision == s.current_revision,
        where: s.enabled == true,
        order_by: [asc: s.id],
        limit: ^(limit + 1),
        select: {s, r}
      )
      |> filter_catalog_view(opts[:view])
      |> maybe_after(after_id)
      |> maybe_query(Keyword.get(opts, :q))
      |> maybe_tag(Keyword.get(opts, :tag))

    rows = Repo.all(query)
    page = Enum.take(rows, limit)

    %{
      data: Enum.map(page, &descriptor(&1, fields)),
      next_cursor: if(length(rows) > limit, do: page |> List.last() |> elem(0) |> Map.fetch!(:id))
    }
  end

  defp filter_catalog_view(query, "always"),
    do: where(query, [s], s.always_return and s.publication_status == "ready")

  defp filter_catalog_view(query, _), do: query

  defp discovery_fields("always", fields), do: [:disable_model_invocation | fields]
  defp discovery_fields(_, fields), do: fields

  @doc "Search enabled, current publications with stable relevance and identity ordering."
  def search(opts) do
    text = Keyword.fetch!(opts, :q)
    limit = Keyword.fetch!(opts, :limit)

    ranked =
      from(s in Skill,
        where: s.enabled and s.publication_status == "ready",
        where:
          fragment(
            "?.search_vector @@ plainto_tsquery('english', ?) OR lower(?) = ANY(SELECT lower(t) FROM unnest(?) AS t) OR lower(?) = lower(?) OR lower(?) = lower(?)",
            s,
            ^text,
            ^text,
            s.tags,
            s.slug,
            ^text,
            s.name,
            ^text
          ),
        select: %{
          id: s.id,
          score:
            fragment(
              "CAST((ts_rank(?.search_vector, plainto_tsquery('english', ?)) + CASE WHEN lower(?) = lower(?) THEN 2 ELSE 0 END) * 1000000 AS bigint)",
              s,
              ^text,
              s.name,
              ^text
            )
        }
      )

    query =
      from(s in Skill,
        join: r in Revision,
        on: r.skill_id == s.id and r.revision == s.current_revision,
        join: hit in subquery(ranked),
        on: hit.id == s.id,
        order_by: [desc: hit.score, asc: s.id],
        limit: ^(limit + 1),
        select: {s, r, hit.score}
      )
      |> maybe_tag(opts[:tag])

    query =
      case opts[:after] do
        [score, id] ->
          where(query, [s, _, hit], hit.score < ^score or (hit.score == ^score and s.id > ^id))

        nil ->
          query
      end

    {page, remaining} = query |> Repo.all() |> Enum.split(limit)
    fields = [:disable_model_invocation | Keyword.get(opts, :fields, [])]

    next_cursor =
      if remaining != [] do
        {skill, _, score} = List.last(page)
        [score, skill.id]
      end

    %{
      data: Enum.map(page, fn {s, r, _} -> descriptor({s, r}, fields) end),
      next_cursor: next_cursor
    }
  end

  @spec backfill(keyword()) :: map()
  def backfill(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    blob_opts = Keyword.get(opts, :blob, [])

    initial = %{
      published: [],
      publishable: [],
      unchanged: [],
      missing: [],
      invalid: [],
      unsupported: []
    }

    Skill
    |> order_by([s], asc: s.id)
    |> Repo.all()
    |> Enum.reduce(initial, fn skill, report ->
      backfill_skill(skill, report, dry_run?, blob_opts)
    end)
    |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  @spec referenced_blob?(String.t()) :: boolean()
  def referenced_blob?(blob_ref) when is_binary(blob_ref) do
    Repo.exists?(from(s in Skill, where: s.archive_ref == ^blob_ref)) or
      Repo.exists?(from(r in Revision, where: r.blob_ref == ^blob_ref))
  end

  defp publish_locked(skill_id, bundle, blob_ref) do
    Repo.transact(fn ->
      lock_skill_id(skill_id)

      case Repo.get(Skill, skill_id) do
        nil -> Repo.rollback(:not_found)
        skill -> {:ok, unwrap(commit(skill, bundle, blob_ref))}
      end
    end)
  end

  defp publish_generated_locked(attrs, bundle, blob_ref) do
    Repo.transact(fn ->
      id = fetch(attrs, :id)
      slug = fetch(attrs, :slug)
      lock_skill_id(id)
      lock_skill_id("slug:" <> slug)

      skill =
        case Repo.get_by(Skill, slug: slug) do
          nil ->
            unwrap(Repo.insert(Skill.changeset(%Skill{}, Map.put(attrs, :archive_ref, blob_ref))))

          %Skill{id: ^id} = skill ->
            if attrs[:source_kind] == "github" and github_source_conflict?(skill, attrs),
              do: Repo.rollback(:reserved_slug_conflict)

            unwrap(Repo.update(Skill.changeset(skill, Map.put(attrs, :archive_ref, blob_ref))))

          %Skill{} ->
            Repo.rollback(:reserved_slug_conflict)
        end

      {:ok, unwrap(commit(skill, bundle, blob_ref))}
    end)
  end

  defp github_source_conflict?(skill, attrs) do
    case (skill.meta || %{})["github_source_id"] do
      nil ->
        skill.source_kind != "github" or skill.source_uri != attrs.source_uri

      id ->
        id != attrs.meta["github_source_id"] or
          skill.meta["github_source_path"] != attrs.meta["github_source_path"]
    end
  end

  defp with_generated_bundle(attrs, name, callback, invalid) do
    if valid_name?(name),
      do: with_temp_bundle(attrs, name, callback, invalid),
      else: invalid.(:invalid_slug)
  end

  defp with_temp_bundle(attrs, name, callback, invalid) do
    base = temporary_directory!("backplane-generated-skill")

    root = Path.join(base, name)
    archive = Path.join(base, "skill.tar.gz")

    try do
      File.mkdir_p!(root)
      File.write!(Path.join(root, "SKILL.md"), generated_document(attrs, name))

      case Bundle.pack(root, archive,
             ref: %SkillRef{source_id: @source_id, skill_id: fetch(attrs, :id)}
           ) do
        {:ok, bundle} -> callback.(bundle)
        {:error, reason} -> invalid.(reason)
      end
    after
      File.rm_rf(base)
    end
  end

  defp generated_document(attrs, name) do
    description = fetch(attrs, :description)
    tags = Map.get(attrs, :tags, Map.get(attrs, "tags", []))
    version = Map.get(attrs, :version, Map.get(attrs, "version"))

    metadata =
      (fetch(attrs, :meta) || %{})
      |> Map.merge(%{"name" => name, "description" => description, "tags" => tags})
      |> maybe_put("license", fetch(attrs, :license))
      |> maybe_put("version", version)

    "---\n" <> JSON.encode!(metadata) <> "\n---\n\n" <> fetch(attrs, :content)
  end

  defp record_generated_invalid(attrs, reason) do
    Repo.transact(fn ->
      id = fetch(attrs, :id)
      slug = fetch(attrs, :slug)
      lock_skill_id(id)

      skill =
        case Repo.get_by(Skill, slug: slug) do
          nil -> unwrap(Repo.insert(Skill.changeset(%Skill{}, attrs)))
          %Skill{id: ^id} = skill -> unwrap(Repo.update(Skill.changeset(skill, attrs)))
          %Skill{} -> Repo.rollback(:reserved_slug_conflict)
        end

      {:ok, unwrap(mark_invalid(skill, reason))}
    end)
  end

  defp backfill_skill(%Skill{archive_ref: nil} = skill, report, _dry, _blob),
    do: add_report(report, :unsupported, skill, :missing_archive)

  defp backfill_skill(%Skill{} = skill, report, dry_run?, blob_opts) do
    case archive_to_temp(skill.archive_ref, blob_opts, fn path ->
           inspect_archive(path, skill.id)
         end) do
      {:error, :not_found} ->
        add_report(report, :missing, skill, :missing_blob)

      {:error, reason} ->
        add_report(report, :invalid, skill, reason)

      {:ok, bundle} ->
        revision = revision_for(bundle.manifest.artifact_digest)

        cond do
          skill.current_revision == revision ->
            add_report(report, :unchanged, skill, revision)

          dry_run? ->
            add_report(report, :publishable, skill, revision)

          true ->
            case publish_locked(skill.id, bundle, skill.archive_ref) do
              {:ok, _} -> add_report(report, :published, skill, revision)
              {:error, reason} -> add_report(report, :invalid, skill, reason)
            end
        end
    end
  end

  defp archive_to_temp(blob_ref, blob_opts, callback) do
    base = temporary_directory!("skill-backfill")
    path = Path.join(base, "artifact.tar.gz")

    try do
      with {:ok, stream} <- Blob.get(blob_ref, blob_opts),
           :ok <- File.write(path, Enum.into(stream, <<>>), [:binary, :exclusive]) do
        callback.(path)
      end
    after
      File.rm_rf(base)
    end
  end

  defp temporary_directory!(prefix) do
    Enum.reduce_while(1..5, nil, fn _, _acc ->
      path =
        Path.join(
          System.tmp_dir!(),
          prefix <> "." <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))
        )

      case File.mkdir(path) do
        :ok -> {:halt, path}
        {:error, :eexist} -> {:cont, nil}
        {:error, reason} -> raise "temporary storage cannot be allocated: #{inspect(reason)}"
      end
    end) || raise "temporary storage collision limit exceeded"
  end

  defp add_report(report, kind, skill, detail) do
    Map.update!(report, kind, &[report_entry(skill, detail) | &1])
  end

  defp report_entry(skill, %Error{} = error),
    do: %{skill_id: skill.id, status: skill.publication_status, reason: diagnostic(error)}

  defp report_entry(skill, detail),
    do: %{skill_id: skill.id, status: skill.publication_status, detail: detail}

  defp descriptor({skill, revision}, fields) do
    metadata = revision.manifest["document_metadata"] || %{}

    descriptor = %{
      skill_id: skill.id,
      name: metadata["name"],
      description: metadata["description"],
      revision: revision.revision,
      artifact_digest: revision.artifact_digest,
      publication_status: skill.publication_status
    }

    descriptor =
      if :disable_model_invocation in fields,
        do:
          Map.put(
            descriptor,
            :disable_model_invocation,
            metadata["disable-model-invocation"] == true
          ),
        else: descriptor

    if :argument_hint in fields,
      do: Map.put(descriptor, :argument_hint, metadata["argument-hint"]),
      else: descriptor
  end

  defp manifest_map(%BundleManifest{} = manifest, skill_id) do
    ref = %SkillRef{
      source_id: @source_id,
      skill_id: skill_id,
      revision: revision_for(manifest.artifact_digest),
      artifact_digest: manifest.artifact_digest
    }

    manifest
    |> Map.put(:ref, ref)
    |> Wire.manifest_map()
  end

  defp revision_for("sha256:" <> digest), do: "r-" <> digest

  defp diagnostic(%Error{} = error) do
    %{
      "code" => to_string(error.code),
      "phase" => to_string(error.phase),
      "message" => error.message,
      "retryable" => error.retryable
    }
  end

  defp diagnostic(reason),
    do: %{"code" => "publication_failed", "message" => inspect(reason), "retryable" => false}

  defp lock_skill_id(value) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [value])
    :ok
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_after(query, nil), do: query
  defp maybe_after(query, after_id), do: where(query, [s, _r], s.id > ^after_id)

  defp maybe_query(query, value) when value in [nil, ""], do: query

  defp maybe_query(query, value) do
    pattern = "%#{String.replace(value, ["%", "_"], "")}%"

    where(
      query,
      [_s, r],
      fragment("(?->'document_metadata'->>'name') ILIKE ?", r.manifest, ^pattern)
    )
  end

  defp maybe_tag(query, value) when value in [nil, ""], do: query

  defp maybe_tag(query, value),
    do:
      where(
        query,
        [_s, r],
        fragment("jsonb_exists(?->'document_metadata'->'tags', ?)", r.manifest, ^value)
      )
end
