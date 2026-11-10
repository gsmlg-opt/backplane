defmodule Backplane.Memory.HostSnapshots do
  @moduledoc """
  Applies `host.snapshot.collected` events as deterministic `host_collector` facts.

  Each (host, collector, unit) has one state row recording the fact slots written by
  the last applied snapshot. Applying a snapshot diffs against it inside one
  transaction holding that row's lock: changed slots are rewritten, vanished slots
  are forgotten only when the scan was complete (or the item itself is still present).
  """

  import Ecto.Query

  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.HostSnapshots.{Facts, State}
  alias Backplane.Memory.{Record, Records}

  @spec apply(Event.t()) ::
          {:ok, %{written: non_neg_integer(), forgotten: non_neg_integer()}}
          | {:ok, :stale}
          | {:error, term()}
  def apply(%Event{} = event) do
    with {:ok, snapshot} <- Facts.validate(event.payload),
         {:ok, new} <- build_slots(event.host_id, snapshot) do
      transaction(event, snapshot, new)
    end
  end

  defp build_slots(host_id, %{collector: collector, items: items}) do
    slots =
      for item <- items,
          key = Facts.item_key(collector, item),
          fact <- Facts.facts(host_id, collector, item),
          into: %{} do
        {fact.slot, {key, fact}}
      end

    {:ok, slots}
  rescue
    _ -> {:error, :invalid_item}
  end

  defp transaction(event, snapshot, new) do
    # A host clock ahead of the gateway must not make later snapshots look stale:
    # order and record by the gateway-clamped time (Records clamps observed_at the same way).
    event = %{event | occurred_at: earliest(event.occurred_at, DateTime.utc_now())}

    result =
      repo().transaction(fn ->
        state = lock_state(event.host_id, snapshot)

        if stale?(state, event) do
          :stale
        else
          diff(event, snapshot, new, state)
        end
      end)

    case result do
      {:ok, :stale} -> {:ok, :stale}
      {:ok, counts} -> {:ok, counts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)

  defp lock_state(host_id, %{collector: collector, unit: unit}) do
    now = DateTime.utc_now()

    repo().insert_all(
      State,
      [
        %{
          host_id: host_id,
          collector: collector,
          unit: unit,
          slots: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:host_id, :collector, :unit]
    )

    State
    |> where([s], s.host_id == ^host_id and s.collector == ^collector and s.unit == ^unit)
    |> lock("FOR UPDATE")
    |> repo().one!()
  end

  defp stale?(%State{collected_at: nil}, _event), do: false

  defp stale?(%State{collected_at: at}, event),
    do: DateTime.compare(at, event.occurred_at) != :lt

  defp diff(event, snapshot, new, state) do
    old = state.slots
    written = Enum.count(new, fn {slot, {key, fact}} -> write(event, slot, key, fact, old) end)

    present_items = MapSet.new(new, fn {_slot, {key, _fact}} -> key end)

    removed = Map.drop(old, Map.keys(new))

    {forget, keep} =
      Enum.split_with(removed, fn {_slot, %{"item" => item}} ->
        snapshot.complete or MapSet.member?(present_items, item)
      end)

    forgotten =
      Enum.reduce(forget, 0, fn {slot, _}, acc -> acc + forget_slot(event, snapshot, slot) end)

    slots =
      new
      |> Map.new(fn {slot, {key, fact}} ->
        {slot, %{"item" => key, "hash" => hash(fact.content)}}
      end)
      |> Map.merge(Map.new(keep))

    state
    |> Ecto.Changeset.change(%{collected_at: event.occurred_at, event_id: event.id, slots: slots})
    |> repo().update!()

    %{written: written, forgotten: forgotten}
  end

  defp write(event, slot, _key, fact, old) do
    content_hash = hash(fact.content)

    if get_in(old, [slot, "hash"]) == content_hash do
      false
    else
      attrs = %{
        "kind" => "fact",
        "writer" => "host_collector",
        "integration" => "host_collector",
        "host_id" => event.host_id,
        "agent_id" => event.agent_id,
        "subjects" => fact.subjects,
        "property" => fact.property,
        "content" => fact.content,
        "observed_at" => event.occurred_at,
        "source_event_ids" => [event.id],
        "request_key" => "host_collector:" <> event.id <> ":" <> hash(slot)
      }

      case Records.remember(attrs) do
        {:ok, _} -> true
        {:error, reason} -> repo().rollback(reason)
      end
    end
  end

  defp forget_slot(event, snapshot, slot) do
    [property, keys] = String.split(slot, "|", parts: 2)

    reason =
      "no longer present in host collector snapshot (#{snapshot.collector}:#{snapshot.unit})"

    Record
    |> where(
      [r],
      r.kind == "fact" and r.writer == "host_collector" and r.status == "active" and
        r.host_id == ^event.host_id and r.property == ^property
    )
    |> repo().all()
    |> Enum.filter(&(Enum.join(&1.subject_keys, ",") == keys))
    |> Enum.count(fn record ->
      case Records.forget(record.id, reason) do
        {:ok, _} -> true
        {:error, why} -> repo().rollback({:forget_failed, record.id, why})
      end
    end)
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
