defmodule Backplane.Memory.Operations.Repair do
  @moduledoc """
  Authorized, partition-scoped and idempotent operator repairs.

  Successful dispatch is recorded in the append-only audit ledger in the same
  database transaction as durable job insertion or synchronous repair work.
  Reusing an idempotency key returns the recorded outcome without dispatching
  duplicate work.
  """

  import Ecto.Query

  alias Backplane.Memory.{Audit, Crystals, Lessons}
  alias Backplane.Memory.Coordination.Lease
  alias Backplane.Memory.Memories.{Memory, Relation, Relations}
  alias Backplane.Memory.Projections.{ActivityVerifier, ProjectedSession, Rebuild, State}

  alias Backplane.Memory.Workers.{
    EmbedWorker,
    GraphExtractWorker,
    ProfileBuildWorker,
    SummaryWorker
  }

  @operation "memory.repair"
  @kinds ~w(
    coordination failed_projections reembed graph profile activity summary crystal
    relation lesson dead_letter
  )
  @limit 100

  @spec run(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def run(args, partition, actor)
      when is_map(args) and is_map(partition) and is_binary(actor) do
    with {:ok, kind} <- required_kind(args),
         {:ok, key} <- required(args, "idempotency_key"),
         {:ok, partition} <- exact_partition(partition) do
      caller_key = caller_key(partition, key)
      request_key = request_key(partition, args, key)

      case repo().transaction(fn ->
             run_once(kind, args, partition, actor, caller_key, request_key)
           end) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          audit_failure(kind, args, partition, actor, caller_key, request_key, reason)
          {:error, reason}
      end
    end
  end

  def run(_args, _partition, _actor), do: {:error, :invalid_arguments}

  def kinds, do: @kinds

  defp run_once(kind, args, partition, actor, caller_key, request_key) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      @operation <> ":" <> caller_key
    ])

    case successful_audit(caller_key) do
      %{metadata: %{"request_fingerprint" => ^request_key} = metadata} ->
        %{
          status: "already_applied",
          kind: kind,
          affected: metadata["affected"] || 0
        }

      %{metadata: _metadata} ->
        repo().rollback(:idempotency_conflict)

      nil ->
        if conflicting_audit?(caller_key, request_key) do
          repo().rollback(:idempotency_conflict)
        end

        case dispatch(kind, Map.put(args, "__actor__", actor), partition) do
          {:ok, affected, targets, details} ->
            metadata =
              partition
              |> Map.merge(%{
                kind: kind,
                affected: affected,
                result: "dispatched",
                idempotency_key: request_key,
                caller_key_hash: caller_key,
                request_fingerprint: request_key
              })
              |> Map.merge(details)

            :ok = Audit.log_once(@operation, actor, targets, request_key, metadata)
            %{status: "dispatched", kind: kind, affected: affected}

          {:error, reason} ->
            repo().rollback(reason)
        end
    end
  end

  defp dispatch("coordination", _args, partition) do
    now = DateTime.utc_now()

    query =
      from(l in Lease,
        where:
          l.host_id == ^partition.host_id and l.client_id == ^partition.client_id and
            l.scope == ^partition.scope and l.namespace == ^partition.namespace and
            l.expires_at < ^now,
        select: l.id
      )

    ids = repo().all(query)
    {count, _} = repo().delete_all(query)
    {:ok, count, ids, %{repair_scope: "expired_leases"}}
  end

  defp dispatch("failed_projections", _args, partition) do
    sessions =
      repo().all(
        from(session in ProjectedSession,
          join: state in State,
          on: state.subject_type == "captured_session" and state.subject_id == session.subject_id,
          where:
            session.host_id == ^partition.host_id and
              session.client_id == ^partition.client_id and session.scope == ^partition.scope and
              session.namespace == ^partition.namespace and
              state.status in ["failed", "dead_letter"],
          distinct: [session.host_id, session.session_id],
          order_by: [asc: session.host_id, asc: session.session_id],
          limit: @limit,
          select: {session.host_id, session.session_id, session.subject_id}
        )
      )

    reduce_repairs(sessions, fn {host_id, session_id, _subject_id} ->
      Rebuild.session(host_id, session_id)
    end)
    |> case do
      :ok -> {:ok, length(sessions), Enum.map(sessions, &elem(&1, 2)), %{bounded: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("reembed", args, partition) do
    with {:ok, id} <- required(args, "target_id"),
         %Memory{} <- owned_memory(id, partition),
         {:ok, %Oban.Job{}} <- EmbedWorker.enqueue(id) do
      {:ok, 1, [id], %{repair_scope: "memory_embedding"}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :dispatch_failed}
    end
  end

  defp dispatch("graph", args, partition) do
    with {:ok, session_id} <- required(args, "session_id"),
         %ProjectedSession{} = session <- owned_session(session_id, partition),
         {:ok, %Oban.Job{}} <- GraphExtractWorker.enqueue(session_id, partition) do
      {:ok, 1, [session.subject_id], %{session_id: session_id}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :dispatch_failed}
    end
  end

  defp dispatch("profile", args, partition) do
    with {:ok, project} <- required(args, "project"),
         true <- project_exists?(project, partition),
         {:ok, %Oban.Job{}} <- ProfileBuildWorker.enqueue(project, partition, force: true) do
      {:ok, 1, [project], %{project: project}}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :dispatch_failed}
    end
  end

  defp dispatch("activity", args, partition) do
    opts =
      [
        host_id: partition.host_id,
        client_id: partition.client_id,
        scope: partition.scope,
        namespace: partition.namespace
      ]
      |> optional_date(:date_from, args["date_from"])
      |> optional_date(:date_to, args["date_to"])

    case ActivityVerifier.repair(opts) do
      {:ok, result} ->
        affected = result.repaired_subjects + result.orphan_contributions_removed
        {:ok, affected, [], %{bounded: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch("summary", args, partition) do
    with {:ok, session_id} <- required(args, "session_id"),
         %ProjectedSession{input_revision: revision} = session
         when is_binary(revision) <- owned_session(session_id, partition),
         {:ok, %Oban.Job{}} <- SummaryWorker.enqueue(session.host_id, session_id, revision) do
      {:ok, 1, [session.subject_id], %{session_id: session_id}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_ready}
    end
  end

  defp dispatch("crystal", args, partition) do
    with {:ok, session_id} <- required(args, "session_id"),
         {:ok, _result} <- Crystals.enqueue_session(session_id, partition) do
      {:ok, 1, [session_id], %{session_id: session_id}}
    end
  end

  defp dispatch("relation", args, partition) do
    with {:ok, relation_id} <- required(args, "target_id"),
         {:ok, resolution} <- relation_resolution(args["resolution"]),
         %Relation{} <- owned_relation(relation_id, partition),
         {:ok, _relation} <- Relations.resolve_candidate(relation_id, resolution) do
      {:ok, 1, [relation_id], %{resolution: Atom.to_string(resolution)}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp dispatch("lesson", args, partition) do
    with {:ok, memory_id} <- required(args, "target_id"),
         {:ok, target} <- lesson_target(args["action"]),
         {:ok, reason} <- required(args, "reason"),
         {:ok, _lesson} <-
           Lessons.transition(memory_id, target, reason, args["idempotency_key"], partition, %{
             actor: args["__actor__"],
             request_id: args["idempotency_key"],
             correlation_id: args["idempotency_key"]
           }) do
      {:ok, 1, [memory_id], %{transition: target}}
    end
  end

  defp dispatch("dead_letter", _args, partition) do
    jobs =
      repo().all(
        from(job in Oban.Job,
          where: job.state in ["discarded", "cancelled"],
          where: like(job.queue, "memory%"),
          where:
            fragment("?->>'host_id' = ?", job.args, ^partition.host_id) and
              fragment("?->>'client_id' = ?", job.args, ^partition.client_id) and
              fragment("?->>'scope' = ?", job.args, ^partition.scope) and
              fragment("?->>'namespace' = ?", job.args, ^partition.namespace),
          order_by: [asc: job.id],
          limit: @limit
        )
      )

    Enum.each(jobs, &Oban.retry_job/1)
    {:ok, length(jobs), Enum.map(jobs, &to_string(&1.id)), %{bounded: true}}
  end

  defp dispatch(_kind, _args, _partition), do: {:error, :invalid_arguments}

  defp reduce_repairs(rows, fun) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case fun.(row) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp owned_memory(id, partition) do
    repo().one(
      from(m in Memory,
        where:
          m.id == ^id and m.host_id == ^partition.host_id and
            m.client_id == ^partition.client_id and m.scope == ^partition.scope and
            m.namespace == ^partition.namespace and is_nil(m.deleted_at)
      )
    )
  end

  defp owned_session(session_id, partition) do
    repo().one(
      from(s in ProjectedSession,
        where:
          s.session_id == ^session_id and s.host_id == ^partition.host_id and
            s.client_id == ^partition.client_id and s.scope == ^partition.scope and
            s.namespace == ^partition.namespace
      )
    )
  end

  defp project_exists?(project, partition) do
    repo().exists?(
      from(s in ProjectedSession,
        where:
          s.project == ^project and s.host_id == ^partition.host_id and
            s.client_id == ^partition.client_id and s.scope == ^partition.scope and
            s.namespace == ^partition.namespace
      )
    )
  end

  defp owned_relation(id, partition) do
    repo().one(
      from(r in Relation,
        join: source in Memory,
        on: source.id == r.source_memory_id,
        join: target in Memory,
        on: target.id == r.target_memory_id,
        where:
          r.id == ^id and source.host_id == ^partition.host_id and
            source.client_id == ^partition.client_id and source.scope == ^partition.scope and
            source.namespace == ^partition.namespace and target.host_id == ^partition.host_id and
            target.client_id == ^partition.client_id and target.scope == ^partition.scope and
            target.namespace == ^partition.namespace,
        select: r
      )
    )
  end

  defp successful_audit(caller_key) do
    repo().one(
      from(row in "memory_audit_log",
        where: row.operation == ^@operation,
        where: fragment("?->>'caller_key_hash' = ?", row.metadata, ^caller_key),
        where: fragment("?->>'result' = 'dispatched'", row.metadata),
        limit: 1,
        select: %{metadata: row.metadata}
      )
    )
  end

  defp conflicting_audit?(caller_key, request_key) do
    repo().exists?(
      from(row in "memory_audit_log",
        where: row.operation == ^@operation,
        where: fragment("?->>'caller_key_hash' = ?", row.metadata, ^caller_key),
        where: fragment("?->>'request_fingerprint' <> ?", row.metadata, ^request_key)
      )
    )
  end

  defp audit_failure(kind, args, partition, actor, caller_key, request_key, reason) do
    metadata =
      partition
      |> Map.merge(%{
        kind: kind,
        result: "failed",
        error_class: error_class(reason),
        idempotency_key: request_key,
        request_fingerprint: request_key
      })
      |> maybe_put_caller_key(caller_key, reason)

    Audit.log_once(
      @operation,
      actor,
      Enum.filter([args["target_id"], args["session_id"]], &is_binary/1),
      request_key <> ":failed:" <> error_class(reason),
      metadata
    )
  end

  defp maybe_put_caller_key(metadata, _caller_key, :idempotency_conflict), do: metadata

  defp maybe_put_caller_key(metadata, caller_key, _reason),
    do: Map.put(metadata, :caller_key_hash, caller_key)

  defp required_kind(args) do
    with {:ok, kind} <- required(args, "kind"), true <- kind in @kinds do
      {:ok, kind}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  defp required(args, key) do
    case args[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :invalid_arguments}, else: {:ok, value}

      _ ->
        {:error, :invalid_arguments}
    end
  end

  defp exact_partition(partition) do
    keys = [:host_id, :client_id, :scope, :namespace]

    if Enum.all?(keys, &(is_binary(partition[&1]) and String.trim(partition[&1]) != "")),
      do: {:ok, Map.take(partition, keys)},
      else: {:error, :unauthorized}
  end

  defp relation_resolution("confirmed"), do: {:ok, :confirmed}
  defp relation_resolution("rejected"), do: {:ok, :rejected}
  defp relation_resolution(_), do: {:error, :invalid_arguments}

  defp lesson_target("promote"), do: {:ok, "active"}
  defp lesson_target("activate"), do: {:ok, "active"}
  defp lesson_target("archive"), do: {:ok, "archived"}
  defp lesson_target("dispute"), do: {:ok, "disputed"}
  defp lesson_target("supersede"), do: {:ok, "superseded"}
  defp lesson_target(_), do: {:error, :invalid_arguments}

  defp optional_date(opts, _key, nil), do: opts
  defp optional_date(opts, key, value), do: Keyword.put(opts, key, value)

  defp caller_key(partition, key) do
    [partition.host_id, partition.client_id, partition.scope, partition.namespace, key]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp request_key(partition, args, key) do
    request = %{
      "partition" => Map.new(partition, fn {field, value} -> {Atom.to_string(field), value} end),
      "caller_key" => key,
      "arguments" => Map.drop(args, ["idempotency_key", "__actor__"])
    }

    {:ok, encoded} = Backplane.Memory.CanonicalJSON.encode(request)

    encoded
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(_), do: "unknown"
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
