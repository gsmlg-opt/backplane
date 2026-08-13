defmodule Backplane.Memory.Workers.EvictionWorkerTest do
  use Backplane.Memory.DataCase, async: false

  import Ecto.Query

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Memory, as: MemorySchema
  alias Backplane.Memory.Workers.EvictionWorker

  @settings_table :backplane_settings

  defp set_setting(key, value) do
    :ets.insert(@settings_table, {key, value})
  end

  defp restore_setting(key, original) do
    case original do
      :missing -> :ets.delete(@settings_table, key)
      v -> :ets.insert(@settings_table, {key, v})
    end
  end

  defp get_original(key) do
    case :ets.lookup(@settings_table, key) do
      [{_, v}] -> v
      [] -> :missing
    end
  end

  defp set_accessed_at(id, dt) do
    repo().update_all(from(m in MemorySchema, where: m.id == ^id), set: [accessed_at: dt])
  end

  defp set_confidence(id, confidence) do
    repo().update_all(from(m in MemorySchema, where: m.id == ^id), set: [confidence: confidence])
  end

  defp deleted?(id) do
    from(m in MemorySchema, where: m.id == ^id, select: m.deleted_at)
    |> repo().one()
    |> then(&(!is_nil(&1)))
  end

  defp archived?(id), do: lifecycle(id) == {nil, "archived"}

  defp lifecycle(id) do
    repo().one(
      from(m in MemorySchema,
        where: m.id == ^id,
        select: {m.deleted_at, m.lifecycle_state}
      )
    )
  end

  describe "perform/1" do
    test "rechecks eligibility after selection so a confidence update prevents eviction" do
      {:ok, mem} = Memories.remember("racing memory", agent_id: "a", host_id: "h")
      now = DateTime.utc_now()
      old_dt = DateTime.add(now, -100 * 86_400, :second)
      set_accessed_at(mem.id, old_dt)
      set_confidence(mem.id, 0.1)

      assert mem.id in EvictionWorker.candidate_ids(now, 30, 0.1, 100)

      set_confidence(mem.id, 1.0)

      assert 0 == EvictionWorker.evict_candidates([mem.id], now, 30, 0.1)
      refute deleted?(mem.id)
    end

    test "concurrent workers report each eviction only once" do
      {:ok, mem} = Memories.remember("single weak memory", agent_id: "a", host_id: "h")
      old_dt = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      set_accessed_at(mem.id, old_dt)
      set_confidence(mem.id, 0.1)

      results =
        1..2
        |> Task.async_stream(
          fn _ -> EvictionWorker.perform(%Oban.Job{args: %{"batch_size" => 100}}) end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, {:ok, %{evicted: count}}} -> count end)

      assert Enum.sum(results) == 1
      assert archived?(mem.id)
    end

    test "evicts at most one deterministic batch per run" do
      memories =
        for suffix <- 1..3 do
          {:ok, mem} =
            Memories.remember("batched weak memory #{suffix}", agent_id: "a", host_id: "h")

          old_dt = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
          set_accessed_at(mem.id, old_dt)
          set_confidence(mem.id, 0.1)
          mem
        end

      expected_ids =
        memories
        |> Enum.sort_by(&{&1.inserted_at, &1.id})
        |> Enum.take(2)
        |> Enum.map(& &1.id)

      assert EvictionWorker.candidate_ids(DateTime.utc_now(), 30, 0.1, 2) == expected_ids

      assert {:ok, %{evicted: 2}} =
               EvictionWorker.perform(%Oban.Job{args: %{"batch_size" => 2}})

      assert Enum.count(memories, &archived?(&1.id)) == 2

      assert {:ok, %{evicted: 1}} =
               EvictionWorker.perform(%Oban.Job{args: %{"batch_size" => 2}})

      assert Enum.all?(memories, &archived?(&1.id))
    end

    test "archives memories where strength * confidence is below threshold and audits it" do
      # Insert a memory with a very old accessed_at so it decays heavily
      {:ok, mem} = Memories.remember("old weak memory", agent_id: "a", host_id: "h")

      # Set accessed_at to 100 days ago; with decay_period=30 and threshold=0.1,
      # decay_steps = div(100, 30) = 3, strength = 1.0 * 0.9^3 = 0.729
      # confidence = 0.1 => final = 0.0729 < 0.1 => evicted
      old_dt = DateTime.add(DateTime.utc_now(), -100 * 86_400, :second)
      set_accessed_at(mem.id, old_dt)
      set_confidence(mem.id, 0.1)

      job = %Oban.Job{args: %{}}
      assert {:ok, %{evicted: evicted}} = EvictionWorker.perform(job)
      assert evicted >= 1

      refute deleted?(mem.id)
      assert {nil, "archived"} = lifecycle(mem.id)

      assert [%{operation: "memory.archive", target_ids: [memory_id], metadata: metadata}] =
               Backplane.Memory.Audit.list(operation: "memory.archive")

      assert memory_id == mem.id
      assert metadata["reason"] == "retention"
    end

    test "leaves strong recent memories untouched" do
      {:ok, mem} = Memories.remember("fresh strong memory", agent_id: "a", host_id: "h")
      # accessed_at defaults to nil -> inserted_at (recent), confidence = 1.0
      # strength ~1.0, 1.0 * 1.0 = 1.0 >> 0.1 threshold

      job = %Oban.Job{args: %{}}
      assert {:ok, _} = EvictionWorker.perform(job)

      refute deleted?(mem.id)
    end

    test "respects memory.eviction_threshold setting via ETS" do
      key = "memory.eviction_threshold"
      original = get_original(key)
      on_exit(fn -> restore_setting(key, original) end)

      # Set threshold very high so even fresh memories get evicted (strength * 1.0 < 0.99)
      # For a brand-new memory: strength = 1.0, confidence = 1.0, product = 1.0
      # We need product < 0.99 but fresh memory has strength=1.0 and conf=1.0
      # So instead set confidence low enough: 0.05 < 0.99 threshold
      set_setting(key, "0.99")

      {:ok, mem} =
        Memories.remember("should be evicted by high threshold", agent_id: "a", host_id: "h")

      set_confidence(mem.id, 0.05)

      job = %Oban.Job{args: %{}}
      assert {:ok, %{evicted: evicted}} = EvictionWorker.perform(job)
      assert evicted >= 1
      refute deleted?(mem.id)
      assert {nil, "archived"} = lifecycle(mem.id)
    end
  end
end
