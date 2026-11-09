defmodule Backplane.HostAgent.Memory.OutboxSync do
  @moduledoc """
  Flushes the local memory outbox to the gateway and pulls this host's
  changed records back into the local cache.

  One cycle runs only while the host channel is alive. Outbox entries are
  sent in `seq` order. A transport error stops the flush (the entry is retried
  next cycle with the same `request_key`); any other gateway error marks the
  entry `failed` and the flush continues. A `forget` for a record whose
  `remember` is still pending waits for it.
  """

  use GenServer

  require Logger

  alias Backplane.HostAgent.{HubProxy, MemoryProxy}
  alias Backplane.HostAgent.Memory.{Local, Store}

  @pull_limit 200
  @transport_errors [:not_connected, :closed, :disconnected, :noproc, :timeout]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one sync cycle synchronously."
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server \\ __MODULE__), do: GenServer.call(server, :sync_now, :infinity)

  @doc "Requests a sync cycle without waiting; a no-op when the server is not running."
  @spec sync_async(GenServer.server()) :: :ok
  def sync_async(server \\ __MODULE__), do: GenServer.cast(server, :sync_now)

  @impl true
  def init(opts) do
    state = %{
      store: Keyword.get(opts, :store, Store),
      hub_proxy: Keyword.get(opts, :hub_proxy, HubProxy),
      memory_proxy: Keyword.get(opts, :memory_proxy, MemoryProxy),
      interval_ms: Keyword.get(opts, :interval_ms, 5_000),
      batch_size: Keyword.get(opts, :batch_size, 50)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    run_cycle(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    run_cycle(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_cycle(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(%{interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :tick, ms)

  defp schedule(_state), do: :ok

  defp run_cycle(state) do
    if channel_alive?(state.memory_proxy) do
      case flush(state) do
        :ok -> maybe_pull(state)
        {:stopped, reason} -> record_error(state, "flush", reason)
      end
    end

    :ok
  rescue
    error -> Logger.warning("memory outbox sync failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("memory outbox sync failed: #{inspect(reason)}")
  end

  # The pull waits until the outbox is drained so pulled copies never race
  # in-flight uploads (pulled records carry request_key, so an overlap would
  # still merge onto the pending row); the next cycle keeps flushing.
  defp maybe_pull(state) do
    if Local.pending_outbox(state.store, 1) == [] do
      pull(state, decode_cursor(Local.get_state(state.store, "pull_cursor")))
    else
      :ok
    end
  end

  defp channel_alive?(memory_proxy) do
    case memory_proxy.channel() do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  # -- flush --

  defp flush(state) do
    state.store
    |> Local.pending_outbox(state.batch_size)
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case send_entry(state, entry) do
        :ok -> {:cont, :ok}
        {:stop, reason} -> {:halt, {:stopped, reason}}
        :wait -> {:halt, :ok}
      end
    end)
  end

  defp send_entry(state, %{"op" => "remember", "payload" => payload} = entry) do
    state.hub_proxy.call_tool("memory::remember", payload)
    |> handle_result(state, entry, &Map.put(&1, "request_key", payload["request_key"]))
  end

  defp send_entry(state, %{"op" => "forget", "local_id" => local_id} = entry) do
    case remote_id(state.store, local_id) do
      nil ->
        if remember_pending?(state, local_id, entry["seq"]) do
          :wait
        else
          fail(state, entry, "remember_not_synced")
        end

      remote_id ->
        args = %{"id" => remote_id, "reason" => entry["payload"]["reason"]}

        state.hub_proxy.call_tool("memory::forget", args)
        |> handle_result(state, entry, & &1)
    end
  end

  defp send_entry(state, entry), do: fail(state, entry, "unsupported_op")

  defp handle_result({:ok, record}, state, entry, prepare) when is_map(record) do
    case Local.complete(state.store, entry["seq"], prepare.(record)) do
      :ok -> :ok
      {:error, reason} -> fail(state, entry, "local_complete_failed: " <> reason_string(reason))
    end
  end

  defp handle_result({:error, reason}, state, entry, _prepare) do
    if transport_error?(reason) do
      case Local.bump_attempt(state.store, entry["seq"], reason_string(reason)) do
        :ok -> :ok
        {:error, store_reason} -> record_error(state, "bump_attempt", store_reason)
      end

      {:stop, reason}
    else
      fail(state, entry, reason_string(reason))
    end
  end

  defp handle_result(other, state, entry, _prepare),
    do: fail(state, entry, "unexpected_reply: " <> inspect(other))

  defp fail(state, entry, reason) do
    Logger.warning("memory outbox entry #{entry["seq"]} (#{entry["op"]}) failed: #{reason}")

    case Local.fail(state.store, entry["seq"], reason) do
      :ok -> :ok
      {:error, store_reason} -> record_error(state, "fail", store_reason)
    end
  end

  defp remote_id(store, local_id) do
    case Local.get(store, local_id) do
      {:ok, %{"id" => id, "local_id" => ^local_id}} when id != local_id -> id
      _ -> nil
    end
  end

  # Pending entries come in seq order, so a pending remember for this record
  # (always enqueued before its forget) is among the first `batch_size` rows.
  defp remember_pending?(state, local_id, seq) do
    state.store
    |> Local.pending_outbox(state.batch_size)
    |> Enum.any?(&(&1["op"] == "remember" and &1["local_id"] == local_id and &1["seq"] < seq))
  end

  defp transport_error?(reason) when reason in @transport_errors, do: true
  defp transport_error?({:channel_exit, _}), do: true
  defp transport_error?(_reason), do: false

  # -- pull --

  defp pull(state, cursor) do
    case state.hub_proxy.pull_memory(cursor, @pull_limit) do
      {:ok, %{"records" => records} = reply} when is_list(records) ->
        next = Map.get(reply, "cursor")

        with :ok <- apply_remotes(state.store, records),
             :ok <- Local.put_state(state.store, "pull_cursor", Jason.encode!(next)) do
          if length(records) < @pull_limit, do: finish(state), else: pull(state, next)
        else
          {:error, reason} -> record_error(state, "pull", reason)
        end

      {:error, reason} ->
        record_error(state, "pull", reason)

      other ->
        record_error(state, "pull", {:unexpected_reply, other})
    end
  end

  # Records failing validation are skipped; a store error halts the page so
  # the cursor is not advanced and the record is retried next cycle.
  defp apply_remotes(store, records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case Local.upsert_remote(store, record) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, :invalid_subjects} ->
          Logger.warning("memory pull skipped record #{inspect(record["id"])}: invalid_subjects")
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp finish(state) do
    with :ok <- Local.put_state(state.store, "last_sync_at", now()),
         :ok <- Local.put_state(state.store, "last_error", "") do
      :ok
    else
      {:error, reason} -> record_error(state, "sync_state", reason)
    end
  end

  defp decode_cursor(nil), do: nil

  defp decode_cursor(json) do
    case Jason.decode(json) do
      {:ok, cursor} when is_map(cursor) -> cursor
      _ -> nil
    end
  end

  defp record_error(state, phase, reason) do
    message = "#{phase}: #{reason_string(reason)}"
    Logger.warning("memory outbox sync #{message}")
    _ = Local.put_state(state.store, "last_error", Local.truncate_error(message))
    :ok
  end

  defp reason_string(reason) when is_binary(reason), do: reason
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason_string(%{"message" => reason}) when is_binary(reason), do: reason
  defp reason_string(%{"code" => code}) when is_binary(code), do: code
  defp reason_string(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
