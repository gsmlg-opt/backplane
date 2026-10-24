defmodule Backplane.HostAgent.Memory.SourceCommands do
  @moduledoc "External-source commands use the existing authority-bound durable host outbox."
  alias Backplane.HostAgent.Memory.{Access, Store}
  alias Backplane.HostAgent.Memory.Mirror.Store, as: MirrorStore
  alias Backplane.MemorySourceContract, as: Contract
  alias Turso.Result

  def enqueue(target, method, args, agent) do
    with true <- Access.local_owner?(target),
         {:ok, args} <- Contract.validate(method, args) do
      args = args |> Map.delete("memory_access_id") |> Map.put("agent_id", agent)
      id = args["event_id"]

      identity = %{
        "op" => method,
        "access" => Access.claim(target),
        "partition" => target.partition,
        "arguments" => args
      }

      digest = MirrorStore.hash(identity)

      if byte_size(Jason.encode!(identity)) > 500_000 do
        {:error, :payload_too_large}
      else
        Store.transaction(target.store, fn conn ->
          case rows!(conn, "SELECT * FROM memory_outbox WHERE command_id=?", [id]) do
            [row] ->
              if row["payload_digest"] != digest,
                do: DBConnection.rollback(conn, :idempotency_conflict)

            [] ->
              execute!(
                conn,
                "INSERT INTO memory_outbox(op,memory_id,payload,command_id,access_id,authority_version,target_partition,payload_digest,request_key,request_agent_id,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                [
                  method,
                  id,
                  Jason.encode!(Map.put(identity, "command_id", id)),
                  id,
                  target.access_id,
                  target.authority_version,
                  Jason.encode!(target.partition),
                  digest,
                  id,
                  agent,
                  timestamp(),
                  timestamp()
                ]
              )
          end

          receipt!(conn, target, args["source"], id)
        end)
      end
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def status(target, source, id) do
    if Access.local_owner?(target),
      do: Store.transaction(target.store, &receipt!(&1, target, source, id)),
      else: {:error, :unauthorized}
  end

  defp receipt!(conn, target, source, id) do
    row =
      List.first(
        rows!(
          conn,
          "SELECT * FROM memory_outbox WHERE command_id=? AND access_id=? AND authority_version=? AND target_partition=? AND op IN ('source_mutate','source_reconcile')",
          [id, target.access_id, target.authority_version, Jason.encode!(target.partition)]
        )
      )

    if is_nil(row), do: DBConnection.rollback(conn, :not_found)
    args = Jason.decode!(row["payload"])["arguments"]
    if args["source"] != source, do: DBConnection.rollback(conn, :not_found)

    base = %{
      "protocol" => Contract.protocol(),
      "event_id" => id,
      "command_id" => id,
      "status" => "pending",
      "outcome" => nil,
      "canonical_id" => nil,
      "revision" => nil,
      "source_revision" => args["revision"],
      "authority" => "provisional",
      "consistency" => "pending_canonical_ack"
    }

    case row["state"] do
      "done" ->
        result = if row["ack_result"], do: Jason.decode!(row["ack_result"]), else: %{}
        Map.merge(base, result) |> Map.put("status", "committed")

      "dead_letter" ->
        Map.merge(base, %{
          "status" => "rejected",
          "error_code" => row["last_error"] || "delivery_exhausted"
        })

      _ ->
        base
    end
  end

  defp rows!(conn, sql, args) do
    case Store.query(conn, sql, args) do
      {:ok, %Result{rows: rows}} -> rows
      {:error, _} -> DBConnection.rollback(conn, :storage_unavailable)
    end
  end

  defp execute!(conn, sql, args) do
    case Store.execute(conn, sql, args) do
      {:ok, result} -> result
      {:error, _} -> DBConnection.rollback(conn, :storage_unavailable)
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
