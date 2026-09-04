defmodule Backplane.MemorySpaces do
  @moduledoc """
  Stable memory-space ownership and exact host partition authorization.
  """

  import Ecto.Query

  alias Backplane.MemorySpaces.{Entitlement, LegacyAlias, MemorySpace}
  alias Backplane.Repo

  @namespace "private"
  @host_alias_type "host"

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
  def revoke_host(host_id) do
    with {:ok, host_id} <- normalize_host_id(host_id) do
      result =
        transaction(fn ->
          with :ok <- lock_host_authority(host_id) do
            now = now()

            Entitlement
            |> where([entitlement], entitlement.host_id == ^host_id)
            |> Repo.update_all(set: [status: "revoked", default_capture: false, updated_at: now])

            {:ok, :ok}
          end
        end)

      case result do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

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
      status: "active"
    }

    result =
      %Entitlement{}
      |> Entitlement.changeset(attrs)
      |> Repo.insert(
        on_conflict: [
          set: [default_capture: true, status: "active", updated_at: now]
        ],
        conflict_target: [:memory_space_id, :host_id, :scope, :namespace]
      )

    case result do
      {:ok, entitlement} -> {:ok, entitlement}
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
      {:error, _reason} -> {:error, :partition_not_ready}
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
        {:ok, partition(entitlement.memory_space_id, entitlement.scope)}

      [] ->
        {:error, :unauthorized}

      _ ->
        {:error, :ambiguous_partition}
    end
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
