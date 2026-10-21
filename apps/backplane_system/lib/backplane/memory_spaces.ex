defmodule Backplane.MemorySpaces do
  @moduledoc """
  Stable memory-space ownership and exact host partition authorization.
  """

  import Ecto.Query

  alias Backplane.MemorySpaces.{AccessAudit, BackfillIssue, Entitlement, LegacyAlias, MemorySpace}
  alias Backplane.Repo

  @namespace "private"
  @host_alias_type "host"
  @capabilities %{read: "read", deliver: "deliver", remember: "remember", forget: "forget"}
  @private_capabilities @capabilities |> Map.values() |> Enum.sort()

  @type partition :: %{
          memory_space_id: Ecto.UUID.t(),
          scope: String.t(),
          namespace: String.t()
        }

  @spec provision_private_host(Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def provision_private_host(host_id, scope) do
    with {:ok, host_id} <- normalize_host_id(host_id),
         {:ok, scope} <- normalize_required(scope) do
      transaction(fn ->
        with :ok <- lock_host_authority(host_id) do
          do_provision_private_host(host_id, scope)
        end
      end)
    end
  end

  @spec update_default_scope(Ecto.UUID.t(), String.t()) :: :ok | {:error, term()}
  def update_default_scope(host_id, scope) do
    with {:ok, host_id} <- normalize_host_id(host_id),
         {:ok, scope} <- normalize_required(scope) do
      result =
        transaction(fn ->
          with :ok <- lock_host_authority(host_id) do
            do_update_default_scope(host_id, scope)
          end
        end)

      case result do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec revoke_host(Ecto.UUID.t()) :: :ok | {:error, term()}
  def revoke_host(host_id, reason \\ "host_lifecycle_revocation") do
    with {:ok, host_id} <- normalize_host_id(host_id),
         {:ok, reason} <- access_text(reason, 1024) do
      result =
        transaction(fn ->
          with :ok <- lock_host_authority(host_id) do
            operator = %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()}

            rows =
              Repo.all(
                from e in Entitlement,
                  where: e.host_id == ^host_id,
                  order_by: e.id,
                  lock: "FOR UPDATE"
              )

            Enum.each(rows, fn row ->
              case transition(
                     row,
                     %{status: "revoked", default_capture: false},
                     operator,
                     "host_revoke",
                     reason
                   ) do
                {:ok, _} -> :ok
                {:error, error} -> Repo.rollback(error)
              end
            end)

            {:ok, :ok}
          end
        end)

      case result do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Explicitly grants one registered host access to an exact canonical partition."
  def grant_host_access(operator, host_id, target, capabilities, opts) do
    with {:ok, operator} <- access_operator(operator),
         {:ok, host_id} <- access_uuid(host_id),
         {:ok, target} <- access_partition(target),
         true <- is_list(opts) and Keyword.keyword?(opts),
         true <-
           Enum.all?(
             Keyword.keys(opts),
             &(&1 in [:reason, :expected_version, :offline_read_lease_seconds])
           ),
         {:ok, reason} <- access_text(opts[:reason], 1024),
         version when is_integer(version) and version >= 0 <- opts[:expected_version],
         {:ok, attrs} <-
           access_attrs(%{
             capabilities: capabilities,
             offline_read_lease_seconds: Keyword.get(opts, :offline_read_lease_seconds, 0)
           }) do
      transaction(fn ->
        with :ok <- access_host_lock(host_id, "FOR UPDATE"),
             :ok <- active_space(target.memory_space_id) do
          row =
            Repo.one(
              from e in Entitlement,
                where:
                  e.host_id == ^host_id and e.memory_space_id == ^target.memory_space_id and
                    e.scope == ^target.scope and e.namespace == ^target.namespace,
                lock: "FOR UPDATE"
            )

          case row do
            nil when version == 0 ->
              with {:ok, created} <-
                     %Entitlement{}
                     |> Entitlement.changeset(
                       Map.merge(attrs, Map.merge(target, %{host_id: host_id}))
                     )
                     |> Repo.insert(),
                   :ok <- record_access_change(nil, created, operator, "grant", reason) do
                {:ok, descriptor(created)}
              end

            %Entitlement{authority_version: ^version} ->
              with {:ok, updated} <-
                     transition(row, Map.put(attrs, :status, "active"), operator, "grant", reason) do
                resolve_access_issue(updated)
                {:ok, descriptor(updated)}
              end

            _ ->
              {:error, :version_conflict}
          end
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc "Changes only capabilities and offline lease policy with optimistic version matching."
  def change_host_access(operator, access_id, expected_version, attrs, reason) do
    with {:ok, operator} <- access_operator(operator),
         {:ok, access_id} <- access_uuid(access_id),
         {:ok, reason} <- access_text(reason, 1024),
         true <-
           is_map(attrs) and
             Enum.all?(Map.keys(attrs), &(&1 in [:capabilities, :offline_read_lease_seconds])),
         true <- is_integer(expected_version) and expected_version > 0 do
      mutate_access(access_id, expected_version, fn row ->
        with {:ok, validated} <-
               access_attrs(
                 Map.merge(
                   Map.take(row, [:capabilities, :offline_read_lease_seconds])
                   |> Map.update!(:capabilities, &atom_capabilities/1),
                   attrs
                 )
               ),
             {:ok, updated} <- transition(row, validated, operator, "change", reason) do
          resolve_access_issue(updated)
          {:ok, descriptor(updated)}
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc "Revokes an exact access without deleting canonical data or rewriting provenance."
  def revoke_host_access(operator, access_id, expected_version, reason) do
    with {:ok, operator} <- access_operator(operator),
         {:ok, access_id} <- access_uuid(access_id),
         {:ok, reason} <- access_text(reason, 1024),
         true <- is_integer(expected_version) and expected_version > 0 do
      mutate_access(access_id, expected_version, fn row ->
        with {:ok, revoked} <-
               transition(
                 row,
                 %{status: "revoked", default_capture: false},
                 operator,
                 "revoke",
                 reason
               ),
             do: {:ok, descriptor(revoked)}
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc "Admin inventory, including revoked grants and the latest safe audit reason."
  def list_host_access(host_id) do
    with {:ok, host_id} <- access_uuid(host_id) do
      {:ok,
       admin_descriptors(
         Repo.all(from e in Entitlement, where: e.host_id == ^host_id, order_by: e.id)
       )}
    end
  end

  @doc "Admin inventory of every recipient of exactly this canonical partition."
  def list_partition_access(target) do
    with {:ok, target} <- access_partition(target) do
      {:ok,
       admin_descriptors(
         Repo.all(
           from e in Entitlement,
             where:
               e.memory_space_id == ^target.memory_space_id and e.scope == ^target.scope and
                 e.namespace == ^target.namespace,
             order_by: e.id
         )
       )}
    end
  end

  @doc "Preview only; committing operations must use with_host_access/5."
  def resolve_host_access(host_id, selector, operation) do
    with {:ok, host_id} <- access_uuid(host_id),
         :ok <- access_selector(selector),
         true <- Map.has_key?(@capabilities, operation),
         :ok <- registered_host(host_id),
         {:ok, row} <- selected_access(host_id, selector, nil),
         :ok <- access_allowed(row, operation) do
      {:ok, descriptor(row)}
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  @doc "Revalidates host credentials and grant authority under host/entitlement locks."
  def with_host_access(actor, selector, operation, expected_version, fun) do
    with {:ok, identity, check} <- access_actor(actor),
         :ok <- access_selector(selector),
         true <- Map.has_key?(@capabilities, operation),
         true <- is_function(fun, 1),
         true <-
           (selector == :default and is_nil(expected_version)) or
             (is_integer(expected_version) and expected_version > 0) do
      transaction(fn ->
        with :ok <- access_host_lock(identity.host_id, "FOR SHARE"),
             {:ok, row} <- selected_access(identity.host_id, selector, "FOR SHARE"),
             :ok <- check_credential(check, identity),
             :ok <- access_allowed(row, operation),
             :ok <- access_version(row, expected_version) do
          fun.(Map.put(descriptor(row), :actor, identity))
        end
      end)
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  defp mutate_access(access_id, expected_version, fun) do
    transaction(fn ->
      case Repo.get(Entitlement, access_id) do
        nil ->
          {:error, :unauthorized}

        preview ->
          with :ok <- access_host_lock(preview.host_id, "FOR UPDATE") do
            row = Repo.one(from e in Entitlement, where: e.id == ^access_id, lock: "FOR UPDATE")

            if row.authority_version == expected_version,
              do: fun.(row),
              else: {:error, :version_conflict}
          end
      end
    end)
  end

  defp transition(row, attrs, operator, action, reason) do
    if Enum.all?(attrs, fn {key, value} -> Map.fetch!(row, key) == value end) and
         not (action in ["grant", "change"] and pending_access_issue?(row.id)) do
      {:ok, row}
    else
      attrs = Map.put(attrs, :authority_version, row.authority_version + 1)

      with {:ok, updated} <- row |> Entitlement.changeset(attrs) |> Repo.update(),
           :ok <- record_access_change(row, updated, operator, action, reason),
           do: {:ok, updated}
    end
  end

  defp record_access_change(previous, row, operator, action, reason) do
    audit = %AccessAudit{
      request_id: operator.request_id,
      actor_kind: Atom.to_string(operator.kind),
      actor_ref: operator.ref,
      action: action,
      access_id: row.id,
      host_id: row.host_id,
      memory_space_id: row.memory_space_id,
      scope: row.scope,
      namespace: row.namespace,
      reason: reason,
      previous_status: previous && previous.status,
      new_status: row.status,
      previous_capabilities: previous && previous.capabilities,
      new_capabilities: row.capabilities,
      previous_offline_read_lease_seconds: previous && previous.offline_read_lease_seconds,
      new_offline_read_lease_seconds: row.offline_read_lease_seconds,
      previous_authority_version: previous && previous.authority_version,
      new_authority_version: row.authority_version
    }

    with {:ok, _} <- Repo.insert(audit),
         {:ok, _} <-
           Repo.query("SELECT pg_notify('bpm_memory_access_changed', $1)", [
             Jason.encode!(%{
               host_id: row.host_id,
               access_id: row.id,
               authority_version: row.authority_version,
               status: row.status
             })
           ]) do
      :ok
    end
  end

  defp resolve_access_issue(row) do
    Repo.update_all(
      from(i in BackfillIssue,
        where:
          i.source_table == "bpm_memory_space_entitlements" and i.source_id == ^row.id and
            i.reason == "shared_access_requires_disposition" and i.disposition == "pending"
      ),
      set: [disposition: "resolved", resolved_at: now(), updated_at: now()]
    )

    :ok
  end

  defp descriptor(row) do
    %{
      access_id: row.id,
      host_id: row.host_id,
      partition: %{
        memory_space_id: row.memory_space_id,
        scope: row.scope,
        namespace: row.namespace
      },
      status: if(row.status == "active", do: :active, else: :revoked),
      default_capture: row.default_capture,
      capabilities: atom_capabilities(row.capabilities),
      authority_version: row.authority_version,
      offline_read_lease_seconds: row.offline_read_lease_seconds
    }
  end

  defp admin_descriptors([]), do: []

  defp admin_descriptors(rows) do
    ids = Enum.map(rows, & &1.id)

    reasons =
      Repo.all(
        from a in AccessAudit,
          where: a.access_id in ^ids,
          distinct: a.access_id,
          order_by: [a.access_id, desc: a.new_authority_version],
          select: {a.access_id, a.reason}
      )
      |> Map.new()

    Enum.map(rows, &Map.put(descriptor(&1), :latest_audit_reason, reasons[&1.id]))
  end

  defp access_partition(target) when is_map(target) do
    with true <- Enum.sort(Map.keys(target)) == Enum.sort([:memory_space_id, :scope, :namespace]),
         {:ok, id} <- access_uuid(target.memory_space_id),
         {:ok, scope} <- access_text(target.scope, 255),
         {:ok, namespace} <- access_text(target.namespace, 255) do
      {:ok, %{memory_space_id: id, scope: scope, namespace: namespace}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp access_partition(_), do: {:error, :invalid_request}

  defp access_attrs(%{capabilities: caps, offline_read_lease_seconds: lease}) do
    with true <- is_list(caps) and Enum.all?(caps, &Map.has_key?(@capabilities, &1)),
         true <- length(Enum.uniq(caps)) == length(caps),
         true <- :deliver not in caps or :read in caps,
         true <- is_integer(lease) and lease in 0..300,
         true <- lease == 0 or (:read in caps and :deliver in caps) do
      {:ok,
       %{
         capabilities: Enum.map(caps, &Map.fetch!(@capabilities, &1)) |> Enum.sort(),
         offline_read_lease_seconds: lease
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp atom_capabilities(values),
    do: for({atom, string} <- @capabilities, string in values, do: atom) |> Enum.sort()

  defp access_operator(%{kind: kind, request_id: request_id} = operator)
       when kind in [:trusted_operator, :system] do
    with {:ok, request_id} <- access_uuid(request_id),
         {:ok, ref} <-
           if(is_nil(operator[:ref]), do: {:ok, nil}, else: access_text(operator.ref, 255)) do
      {:ok, %{kind: kind, request_id: request_id, ref: ref}}
    end
  end

  defp access_operator(_), do: {:error, :invalid_request}

  defp access_actor(%{host_id: host, credential_id: credential, credential_check: check} = actor)
       when is_function(check, 1) do
    with {:ok, host} <- access_uuid(host),
         {:ok, credential} <- access_uuid(credential),
         true <- is_nil(actor[:source_client_id]) or is_binary(actor[:source_client_id]) do
      {:ok,
       %{host_id: host, credential_id: credential, source_client_id: actor[:source_client_id]},
       check}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp access_actor(_), do: {:error, :unauthorized}

  defp check_credential(check, identity) do
    if check.(identity) == :ok, do: :ok, else: {:error, :unauthorized}
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp access_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_request}
    end
  end

  defp access_text(value, bound) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.length(value) <= bound and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, :invalid_request}
  end

  defp access_text(_, _), do: {:error, :invalid_request}
  defp access_selector(:default), do: :ok

  defp access_selector({:access_id, id}) do
    case access_uuid(id) do
      {:ok, ^id} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp access_selector(_), do: {:error, :invalid_request}

  defp registered_host(id) do
    case Repo.query("SELECT id FROM skill_hosts WHERE id = $1", [Ecto.UUID.dump!(id)]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end

  defp access_host_lock(id, lock) do
    case Repo.query("SELECT id FROM skill_hosts WHERE id = $1 " <> lock, [Ecto.UUID.dump!(id)]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> {:error, :unauthorized}
      {:error, _} = error -> error
    end
  end

  defp active_space(id),
    do:
      if(Repo.exists?(from s in MemorySpace, where: s.id == ^id and s.status == "active"),
        do: :ok,
        else: {:error, :unauthorized}
      )

  defp selected_access(host_id, selector, lock) do
    query = from e in Entitlement, where: e.host_id == ^host_id

    query =
      case selector do
        {:access_id, id} ->
          where(query, [e], e.id == ^id)

        :default ->
          case host_memory_space_id(host_id) do
            {:ok, id} ->
              where(
                query,
                [e],
                e.memory_space_id == ^id and e.default_capture == true and
                  e.namespace == @namespace
              )

            _ ->
              where(query, [e], false)
          end
      end

    query = if lock == "FOR SHARE", do: lock(query, "FOR SHARE"), else: query

    case Repo.one(query) do
      %Entitlement{} = row -> {:ok, row}
      nil -> {:error, :unauthorized}
    end
  end

  defp access_allowed(row, operation) do
    if row.status == "active" and Map.fetch!(@capabilities, operation) in row.capabilities and
         not pending_access_issue?(row.id),
       do: active_space(row.memory_space_id),
       else: {:error, :unauthorized}
  end

  defp pending_access_issue?(id),
    do:
      Repo.exists?(
        from i in BackfillIssue,
          where:
            i.source_table == "bpm_memory_space_entitlements" and i.source_id == ^id and
              i.reason == "shared_access_requires_disposition" and i.disposition == "pending"
      )

  defp access_version(_row, nil), do: :ok
  defp access_version(%{authority_version: version}, version), do: :ok
  defp access_version(_, _), do: {:error, :authority_changed}

  @spec resolve_host_partition(Ecto.UUID.t(), String.t() | nil, String.t()) ::
          {:ok, partition()}
          | {:error, :unauthorized | :ambiguous_partition | :partition_not_ready}
  def resolve_host_partition(host_id, scope, namespace) do
    with {:ok, host_id} <- normalize_host_id(host_id),
         {:ok, namespace} <- normalize_required(namespace),
         {:ok, scope} <- normalize_optional(scope),
         {:ok, memory_space_id} <- host_memory_space_id(host_id) do
      resolve_entitlement(memory_space_id, host_id, scope, namespace)
    else
      {:error, :blank} -> {:error, :unauthorized}
      {:error, :invalid_host_id} -> {:error, :partition_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec private_host_space_id(Ecto.UUID.t()) :: Ecto.UUID.t()
  def private_host_space_id(host_id) do
    digest = :crypto.hash(:md5, "backplane-memory-space:host:" <> host_id)
    {:ok, encoded} = Ecto.UUID.load(digest)
    encoded
  end

  defp do_provision_private_host(host_id, scope) do
    memory_space_id = private_host_space_id(host_id)
    alias_value = host_alias(host_id)
    now = now()

    with {:ok, _space} <-
           %MemorySpace{}
           |> MemorySpace.changeset(%{id: memory_space_id, kind: "private", status: "active"})
           |> Repo.insert(on_conflict: :nothing),
         {:ok, _alias} <- insert_or_validate_alias(alias_value, memory_space_id, now),
         :ok <- clear_defaults(host_id, now),
         {:ok, _entitlement} <- upsert_entitlement(memory_space_id, host_id, scope, now) do
      {:ok, partition(memory_space_id, scope)}
    end
  end

  defp do_update_default_scope(host_id, scope) do
    with {:ok, memory_space_id} <- host_memory_space_id(host_id),
         :ok <- clear_defaults(host_id, now()),
         {:ok, _entitlement} <- upsert_entitlement(memory_space_id, host_id, scope, now()) do
      {:ok, :ok}
    end
  end

  defp insert_or_validate_alias(alias_value, memory_space_id, now) do
    attrs = %{
      alias_type: @host_alias_type,
      alias_value: alias_value,
      memory_space_id: memory_space_id,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(LegacyAlias, [attrs],
      on_conflict: :nothing,
      conflict_target: [:alias_type, :alias_value]
    )

    case Repo.one(
           from(alias_row in LegacyAlias,
             where:
               alias_row.alias_type == ^@host_alias_type and
                 alias_row.alias_value == ^alias_value,
             lock: "FOR UPDATE"
           )
         ) do
      %LegacyAlias{memory_space_id: ^memory_space_id} = alias_row -> {:ok, alias_row}
      %LegacyAlias{} -> {:error, :ambiguous_partition}
      nil -> {:error, :partition_not_ready}
    end
  end

  defp clear_defaults(host_id, now) do
    Entitlement
    |> where([entitlement], entitlement.host_id == ^host_id)
    |> Repo.update_all(set: [default_capture: false, updated_at: now])

    :ok
  end

  defp upsert_entitlement(memory_space_id, host_id, scope, now) do
    attrs = %{
      memory_space_id: memory_space_id,
      host_id: host_id,
      scope: scope,
      namespace: @namespace,
      default_capture: true,
      status: "active",
      capabilities: @private_capabilities
    }

    existing =
      Repo.one(
        from e in Entitlement,
          where:
            e.memory_space_id == ^memory_space_id and e.host_id == ^host_id and e.scope == ^scope and
              e.namespace == @namespace,
          lock: "FOR UPDATE"
      )

    result =
      case existing do
        %Entitlement{status: "revoked"} ->
          {:error, :unauthorized}

        %Entitlement{} = row ->
          row |> Ecto.Changeset.change(default_capture: true, updated_at: now) |> Repo.update()

        nil ->
          with {:ok, row} <- %Entitlement{} |> Entitlement.changeset(attrs) |> Repo.insert(),
               :ok <-
                 record_access_change(
                   nil,
                   row,
                   %{kind: :system, ref: nil, request_id: Ecto.UUID.generate()},
                   "private_provision",
                   "private_host_provisioned"
                 ),
               do: {:ok, row}
      end

    case result do
      {:ok, entitlement} -> {:ok, entitlement}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, changeset} -> {:error, entitlement_error(changeset)}
    end
  end

  defp lock_host_authority(host_id) do
    case Repo.query(
           "SELECT id FROM skill_hosts WHERE id = $1 FOR UPDATE",
           [Ecto.UUID.dump!(host_id)]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :partition_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entitlement_error(changeset) do
    active_default_conflict? =
      Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
        metadata[:constraint_name] ==
          "bpm_memory_space_entitlements_active_default_index"
      end)

    if active_default_conflict?, do: :ambiguous_partition, else: :partition_not_ready
  end

  defp host_memory_space_id(host_id) do
    alias_value = host_alias(host_id)

    ids =
      LegacyAlias
      |> join(:inner, [alias_row], space in MemorySpace,
        on: space.id == alias_row.memory_space_id and space.status == "active"
      )
      |> where(
        [alias_row, _space],
        alias_row.alias_type == ^@host_alias_type and alias_row.alias_value == ^alias_value
      )
      |> select([alias_row, _space], alias_row.memory_space_id)
      |> limit(2)
      |> Repo.all()

    case ids do
      [memory_space_id] -> {:ok, memory_space_id}
      [] -> {:error, :partition_not_ready}
      _ -> {:error, :ambiguous_partition}
    end
  end

  defp resolve_entitlement(memory_space_id, host_id, scope, namespace) do
    query =
      Entitlement
      |> where(
        [entitlement],
        entitlement.memory_space_id == ^memory_space_id and
          entitlement.host_id == ^host_id and entitlement.namespace == ^namespace and
          entitlement.status == "active"
      )
      |> then(fn query ->
        if is_nil(scope) do
          where(query, [entitlement], entitlement.default_capture == true)
        else
          where(query, [entitlement], entitlement.scope == ^scope)
        end
      end)
      |> limit(2)
      |> Repo.all()

    case query do
      [%Entitlement{} = entitlement] ->
        partition = partition(entitlement.memory_space_id, entitlement.scope)

        if unresolved_partition_issue?(host_id, partition),
          do: {:error, :partition_not_ready},
          else: {:ok, partition}

      [] ->
        {:error, :unauthorized}

      _ ->
        {:error, :ambiguous_partition}
    end
  end

  @doc "Legacy private inventory; shared grants require the extended access inventory."
  def host_entitlements(host_id) do
    with {:ok, host_id} <- normalize_host_id(host_id),
         {:ok, private_space} <- host_memory_space_id(host_id) do
      {:ok,
       Repo.all(
         from(e in Entitlement,
           join: s in MemorySpace,
           on: s.id == e.memory_space_id,
           left_join: issue in BackfillIssue,
           on:
             issue.source_table == "bpm_memory_space_entitlements" and
               issue.source_id == fragment("?::text", e.id) and
               issue.reason == "shared_access_requires_disposition" and
               issue.disposition == "pending",
           where:
             e.host_id == ^host_id and e.memory_space_id == ^private_space and
               e.status == "active" and s.status == "active",
           where: "read" in e.capabilities and "deliver" in e.capabilities,
           where: is_nil(issue.id),
           order_by: [e.memory_space_id, e.scope, e.namespace],
           select: %{memory_space_id: e.memory_space_id, scope: e.scope, namespace: e.namespace}
         )
       )}
    end
  end

  @doc "Checks readiness; rebuilding exempts only initial-snapshot issues with this complete exact tuple."
  def partition_ready?(host_id, partition, rebuilding_snapshot \\ false) do
    not unresolved_partition_issue?(host_id, partition, rebuilding_snapshot)
  end

  defp unresolved_partition_issue?(host_id, partition, rebuilding_snapshot \\ false) do
    memory_space_id = partition.memory_space_id
    scope = partition.scope
    namespace = partition.namespace

    query =
      from(issue in BackfillIssue,
        where: issue.disposition == "pending",
        where: issue.reason != "shared_access_requires_disposition",
        where:
          (fragment("? ->> 'memory_space_id' = ?", issue.details, ^memory_space_id) or
             fragment("? ->> 'host_id' = ?", issue.details, ^host_id)) and
            (fragment("nullif(btrim(? ->> 'scope'), '') IS NULL", issue.details) or
               fragment("? ->> 'scope' = ?", issue.details, ^scope)) and
            (fragment("nullif(btrim(? ->> 'namespace'), '') IS NULL", issue.details) or
               fragment("? ->> 'namespace' = ?", issue.details, ^namespace))
      )

    query =
      if rebuilding_snapshot do
        where(
          query,
          [issue],
          not (issue.source_table == "initial_snapshot" and
                 fragment(
                   "? @> ?::jsonb",
                   issue.details,
                   ^%{
                     "memory_space_id" => memory_space_id,
                     "scope" => scope,
                     "namespace" => namespace
                   }
                 ))
        )
      else
        query
      end

    Repo.exists?(query)
  end

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp partition(memory_space_id, scope) do
    %{memory_space_id: memory_space_id, scope: scope, namespace: @namespace}
  end

  defp normalize_host_id(host_id) when is_binary(host_id) do
    case Ecto.UUID.cast(String.trim(host_id)) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_host_id}
    end
  end

  defp normalize_host_id(_host_id), do: {:error, :invalid_host_id}

  defp normalize_optional(nil), do: {:ok, nil}
  defp normalize_optional(value), do: normalize_required(value)

  defp normalize_required(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :blank}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_required(_value), do: {:error, :blank}
  defp host_alias(host_id), do: "host:" <> host_id
  defp now, do: DateTime.utc_now()
end
