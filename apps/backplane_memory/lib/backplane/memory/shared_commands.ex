defmodule Backplane.Memory.SharedCommands do
  @moduledoc "Version-fenced, idempotent canonical settlement of shared Memory commands."

  import Ecto.Query
  alias Backplane.Memory.{Authorization, CanonicalJSON, Memories, PartitionIdentity}
  alias Backplane.Memory.SharedCommands.Receipt
  alias Backplane.MemorySpaces
  alias Backplane.MemorySpaces.Entitlement

  @operations %{
    "remember" => :remember,
    "forget" => :forget,
    "source_mutate" => :source_mutate,
    "source_reconcile" => :source_reconcile
  }
  @codes %{
    "unauthorized" => :unauthorized,
    "authority_changed" => :authority_changed,
    "not_found" => :not_found,
    "invalid_request" => :invalid_request
  }

  @doc "Commits a mutation and its minimal receipt atomically, or returns its saved outcome."
  def settle(auth, envelope) do
    with {:ok, command} <- normalize(envelope),
         {:ok, actor} <- Authorization.host_actor(auth, permission_operation(command.operation)) do
      repo().transaction(fn ->
        case settle_locked(actor, command) do
          {:ok, ack} -> ack
          # Nested transactions share the connection's aborted state. Propagate
          # the original failure explicitly instead of attempting to commit it.
          {:error, reason} -> repo().rollback(reason)
        end
      end)
    end
  end

  defp settle_locked(actor, command) do
    with :ok <- lock_credential(actor),
         %Entitlement{} = access <-
           repo().one(
             from e in Entitlement,
               where: e.id == ^command.access_id and e.host_id == ^actor.host_id,
               lock: "FOR SHARE"
           ) do
      lock_command(actor.host_id, command.access_id, command.command_id)

      receipt =
        repo().one(
          from r in Receipt,
            where:
              r.host_id == ^actor.host_id and r.access_id == ^command.access_id and
                r.command_id == ^command.command_id
        )

      case receipt do
        %Receipt{payload_digest: digest} when digest != command.digest ->
          {:error, :idempotency_conflict}

        %Receipt{} = saved ->
          {:ok, ack(saved, true)}

        nil ->
          settle_new(actor, access, command)
      end
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp settle_new(actor, access, command) do
    target = Map.take(access, [:memory_space_id, :scope, :namespace])

    with true <- target == command.partition,
         :ok <- known_version(command.version, access.authority_version),
         true <-
           not Map.has_key?(command.arguments, "scope") or
             command.arguments["scope"] == target.scope,
         :ok <- validate_arguments(command.operation, command.arguments) do
      case MemorySpaces.resolve_host_access(
             actor.host_id,
             {:access_id, access.id},
             permission_operation(command.operation)
           ) do
        {:ok, current} when current.authority_version != command.version ->
          save(actor, command, {:rejected, :authority_changed})

        {:ok, _} ->
          MemorySpaces.with_host_access(
            actor,
            {:access_id, access.id},
            permission_operation(command.operation),
            command.version,
            fn _ ->
              with :ok <- source_permissions(actor, access, command) do
                case effect(actor, command) do
                  {:ok, %{} = result} ->
                    save(actor, command, {:source, result})

                  {:ok, canonical_id} ->
                    save(
                      actor,
                      command,
                      {:committed, canonical_id, revision(command.partition, canonical_id)}
                    )

                  {:error, :not_found} ->
                    save(actor, command, {:rejected, :not_found})

                  {:error, reason} ->
                    {:error, reason}
                end
              end
            end
          )

        {:error, :unauthorized} ->
          save(actor, command, {:rejected, :unauthorized})

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :partition_mismatch}
      {:error, _} = error -> error
    end
  end

  defp effect(actor, %{operation: :remember} = command) do
    args = command.arguments
    metadata = Map.put(args["metadata"], "host_memory", %{"local_id" => command.command_id})

    opts =
      Map.to_list(command.partition) ++
        [
          host_id: actor.host_id,
          client_id: "host:" <> actor.host_id,
          source_client_id: actor.source_client_id,
          agent_id: args["agent_id"] || "host:" <> actor.host_id,
          type: args["type"],
          tags: args["tags"],
          metadata: metadata,
          session_id: args["session_id"],
          shared_facets: args["facets"],
          idempotency_scope: "memory-shared.v2:" <> actor.host_id <> ":" <> command.access_id,
          idempotency_key: command.command_id
        ]

    with {:ok, memory} <- Memories.remember(args["content"], opts) do
      Backplane.Memory.Audit.log("remember", "host:" <> actor.host_id, [memory.id], %{
        requesting_actor: identity(actor),
        partition: command.partition,
        access_id: command.access_id,
        authority_version: command.version,
        command_id: command.command_id
      })

      {:ok, memory.id}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _} -> {:error, :invalid_request}
    end
  end

  defp effect(actor, %{operation: :forget} = command),
    do: Memories.tombstone_shared(command.arguments["id"], command.partition, identity(actor))

  defp effect(actor, %{operation: operation} = command)
       when operation in [:source_mutate, :source_reconcile] do
    authority =
      Map.merge(command.partition, %{
        host_id: actor.host_id,
        client_id: "host:" <> actor.host_id,
        source_client_id: actor.source_client_id,
        agent_id: command.arguments["agent_id"]
      })

    args = Map.delete(command.arguments, "agent_id")

    if operation == :source_mutate,
      do: Backplane.Memory.Sources.mutate(args, authority),
      else: Backplane.Memory.Sources.reconcile(args, authority)
  end

  defp permission_operation(operation) when operation in [:source_mutate, :source_reconcile],
    do: :remember

  defp permission_operation(operation), do: operation

  defp source_permissions(actor, access, %{operation: operation})
       when operation in [:source_mutate, :source_reconcile] do
    case MemorySpaces.resolve_host_access(actor.host_id, {:access_id, access.id}, :forget) do
      {:ok, current} when current.authority_version == access.authority_version -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp source_permissions(_, _, _), do: :ok

  defp save(actor, command, outcome) do
    attrs =
      %{
        host_id: actor.host_id,
        access_id: command.access_id,
        command_id: command.command_id,
        authority_version: command.version,
        operation: Atom.to_string(command.operation),
        payload_digest: command.digest
      }
      |> Map.merge(command.partition)
      |> Map.merge(
        case outcome do
          {:committed, id, revision} ->
            %{status: "committed", canonical_id: id, revision: revision}

          {:rejected, code} ->
            %{status: "rejected", error_code: Atom.to_string(code)}

          {:source, result} ->
            %{
              status: "committed",
              canonical_id: result[:canonical_id],
              revision: result[:revision],
              result: result |> Map.new(fn {key, value} -> {to_string(key), value} end)
            }
        end
      )

    with {:ok, receipt} <- repo().insert(struct!(Receipt, attrs)), do: {:ok, ack(receipt, false)}
  end

  defp ack(receipt, duplicate?) do
    base = %{
      command_id: receipt.command_id,
      access: %{access_id: receipt.access_id, authority_version: receipt.authority_version},
      partition: Map.take(receipt, [:memory_space_id, :scope, :namespace])
    }

    if receipt.status == "committed" do
      base =
        Map.merge(base, %{
          status: if(duplicate?, do: :duplicate, else: :committed),
          canonical_id: receipt.canonical_id,
          revision: receipt.revision
        })

      if receipt.operation in ~w(source_mutate source_reconcile),
        do: Map.put(base, :source_result, receipt.result),
        else: base
    else
      Map.merge(base, %{status: :rejected, code: Map.fetch!(@codes, receipt.error_code)})
    end
  end

  defp lock_credential(actor) do
    with {:ok, %{num_rows: 1}} <-
           repo().query("SELECT id FROM skill_hosts WHERE id=$1 FOR SHARE", [
             Ecto.UUID.dump!(actor.host_id)
           ]),
         :ok <- actor.credential_check.(identity(actor)),
         do: :ok
  end

  defp lock_command(host, access, command) do
    <<key::signed-64, _::binary>> = :crypto.hash(:sha256, Enum.join([host, access, command], ":"))
    repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
  end

  defp revision(partition, id) do
    repo().one(
      from c in Backplane.Memory.EdgeSync.Change,
        where:
          c.memory_space_id == ^partition.memory_space_id and c.scope == ^partition.scope and
            c.namespace == ^partition.namespace and c.memory_id == ^id,
        select: max(c.revision)
    )
  end

  defp normalize(
         %{
           "command_id" => id,
           "op" => op,
           "access" => access,
           "partition" => target,
           "arguments" => args
         } = envelope
       )
       when map_size(envelope) == 5 and is_map(access) and map_size(access) == 2 and
              is_map(target) and map_size(target) == 3 and is_map(args) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, operation} <- Map.fetch(@operations, op),
         %{"access_id" => access_id, "authority_version" => version} <- access,
         {:ok, access_id} <- Ecto.UUID.cast(access_id),
         true <- is_integer(version) and version > 0,
         true <- Enum.sort(Map.keys(target)) == ~w(memory_space_id namespace scope),
         {:ok, partition} <- PartitionIdentity.validate(target),
         args = normalize_arguments(operation, args),
         true <- operation not in [:source_mutate, :source_reconcile] or args["event_id"] == id,
         {:ok, json} <-
           CanonicalJSON.encode(%{
             "op" => op,
             "access" => %{"access_id" => access_id, "authority_version" => version},
             "partition" => Map.new(partition, fn {key, value} -> {to_string(key), value} end),
             "arguments" => args
           }),
         true <- byte_size(json) <= 524_288 do
      {:ok,
       %{
         command_id: id,
         operation: operation,
         access_id: access_id,
         version: version,
         partition: partition,
         arguments: args,
         digest: :crypto.hash(:sha256, json)
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp normalize(_), do: {:error, :invalid_request}

  defp normalize_arguments(:remember, args),
    do:
      args
      |> Map.put_new("type", "semantic")
      |> Map.put_new("tags", [])
      |> Map.put_new("metadata", %{})
      |> Map.put_new("facets", [])

  defp normalize_arguments(:forget, args), do: args

  defp normalize_arguments(operation, args) when operation in [:source_mutate, :source_reconcile],
    do: args

  defp validate_arguments(:remember, args) do
    valid? =
      Enum.all?(
        Map.keys(args),
        &(&1 in ~w(content type tags metadata agent_id session_id facets scope idempotency_key))
      ) and
        bounded_string?(args["content"], 262_144) and
        args["type"] in ~w(semantic episodic procedural working) and
        is_list(args["tags"]) and length(args["tags"]) <= 100 and
        Enum.all?(args["tags"], &bounded_string?(&1, 512)) and
        is_map(args["metadata"]) and
        not Enum.any?(
          ~w(host_memory host_memory_command_revision requesting_actor),
          &Map.has_key?(args["metadata"], &1)
        ) and
        (is_nil(args["agent_id"]) or bounded_string?(args["agent_id"], 512)) and
        (is_nil(args["session_id"]) or bounded_string?(args["session_id"], 512)) and
        (is_nil(args["idempotency_key"]) or bounded_string?(args["idempotency_key"], 512)) and
        valid_facets?(args["facets"])

    if valid?, do: :ok, else: {:error, :invalid_request}
  end

  defp validate_arguments(:forget, %{"id" => id} = args) when map_size(args) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_request}
    end
  end

  defp validate_arguments(:forget, _), do: {:error, :invalid_request}

  defp validate_arguments(operation, args)
       when operation in [:source_mutate, :source_reconcile] do
    case Backplane.MemorySourceContract.validate(
           Atom.to_string(operation),
           Map.delete(args, "agent_id")
         ) do
      {:ok, _} ->
        if is_nil(args["agent_id"]) or bounded_string?(args["agent_id"], 512),
          do: :ok,
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp valid_facets?(facets) when is_list(facets) and length(facets) <= 100 do
    valid? =
      Enum.all?(facets, fn
        %{"dimension" => dimension, "value" => value} = facet when map_size(facet) == 2 ->
          bounded_string?(dimension, 512) and bounded_string?(value, 1024)

        _ ->
          false
      end)

    if valid? do
      names = facets |> Enum.map(& &1["dimension"]) |> Enum.uniq() |> Enum.sort()

      known =
        repo().all(
          from d in Backplane.Memory.Facets.Dimension,
            where: d.name in ^names,
            order_by: d.name,
            select: d.name
        )

      names == known
    else
      false
    end
  end

  defp valid_facets?(_), do: false

  defp known_version(version, current) when version <= current, do: :ok
  defp known_version(_, _), do: {:error, :invalid_request}

  defp bounded_string?(value, max),
    do:
      is_binary(value) and byte_size(value) in 1..max and String.trim(value) != "" and
        not String.contains?(value, <<0>>)

  defp identity(actor), do: Map.drop(actor, [:credential_check])
  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
