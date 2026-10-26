defmodule Backplane.Api.HostAgentMemorySync do
  @moduledoc """
  Default hub-side adapter for host-agent memory sync protocol events.
  """

  @max_command_bytes 524_288

  @doc "Settle a bounded batch of immutable shared commands without disclosing Memory content."
  def settle_commands(auth, %{"protocol" => "memory_commands.v2", "items" => items} = payload)
      when map_size(payload) == 2 and is_list(items) do
    cond do
      length(items) > 50 or byte_size(Jason.encode!(payload)) > @max_command_bytes ->
        {:error, :payload_too_large}

      not Enum.all?(items, &valid_shared_envelope?/1) ->
        {:error, :invalid_request}

      true ->
        Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acknowledgements} ->
          case Backplane.Memory.SharedCommands.settle(auth, item) do
            {:ok, acknowledgement} ->
              {:cont, {:ok, [acknowledgement | acknowledgements]}}

            {:error, reason} when reason in [:storage_unavailable, :transaction_conflict] ->
              {:halt, {:error, reason}}

            {:error, reason} ->
              code =
                if reason in [
                     :unauthorized,
                     :authority_changed,
                     :invalid_request,
                     :partition_mismatch,
                     :idempotency_conflict,
                     :not_found
                   ],
                   do: reason,
                   else: :invalid_request

              acknowledgement = %{
                command_id: item["command_id"],
                status: :rejected,
                access: item["access"],
                partition: item["partition"],
                code: code
              }

              {:cont, {:ok, [acknowledgement | acknowledgements]}}
          end
        end)
        |> case do
          {:ok, acknowledgements} ->
            {:ok, %{protocol: "memory_commands.v2", items: Enum.reverse(acknowledgements)}}

          error ->
            error
        end
    end
  end

  def settle_commands(_auth, _payload), do: {:error, :invalid_request}

  defp valid_shared_envelope?(
         %{
           "command_id" => id,
           "op" => op,
           "access" => %{"access_id" => access_id, "authority_version" => version} = access,
           "partition" => partition,
           "arguments" => arguments
         } = item
       )
       when map_size(item) == 5 and map_size(access) == 2 and is_map(partition) and
              map_size(partition) == 3 and is_map(arguments) and is_integer(version) and
              version > 0 do
    Ecto.UUID.cast(id) != :error and Ecto.UUID.cast(access_id) != :error and
      op in ["remember", "forget", "source_mutate", "source_reconcile"] and
      Enum.sort(Map.keys(partition)) == ~w(memory_space_id namespace scope) and
      match?({:ok, _}, Backplane.Memory.PartitionIdentity.validate(partition)) and
      Enum.all?(
        [partition["scope"], partition["namespace"]],
        &(is_binary(&1) and byte_size(&1) <= 255)
      )
  end

  defp valid_shared_envelope?(_), do: false
end
