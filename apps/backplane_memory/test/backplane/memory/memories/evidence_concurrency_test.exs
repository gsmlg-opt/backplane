defmodule Backplane.Memory.Memories.EvidenceConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.{Evidence, Memory, RememberRequest}
  alias Ecto.Adapters.SQL.Sandbox

  @timeout 30_000

  test "concurrent identical requests commit one effect" do
    key = unique("identical")
    cleanup_on_exit(key)

    results =
      concurrent_remember(12, fn _ ->
        Memories.remember("concurrent identical #{key}", direct_opts(key))
      end)

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    memory_ids = Enum.map(results, fn {:ok, {:ok, memory}} -> memory.id end)
    assert [_memory_id] = Enum.uniq(memory_ids)

    assert unboxed(fn ->
             repo().aggregate(
               from(r in RememberRequest,
                 where: r.idempotency_scope == "direct" and r.idempotency_key == ^key
               ),
               :count
             )
           end) == 1

    assert evidence_count(memory_ids) == 1
  end

  test "concurrent independent requests reuse one candidate and retain every evidence row" do
    prefix = unique("independent")
    cleanup_on_exit(prefix)

    results =
      concurrent_remember(12, fn n ->
        Memories.remember("concurrent shared #{prefix}", direct_opts("#{prefix}:#{n}"))
      end)

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    memory_ids = Enum.map(results, fn {:ok, {:ok, memory}} -> memory.id end)
    assert [_memory_id] = Enum.uniq(memory_ids)
    assert evidence_count(memory_ids) == 12

    assert unboxed(fn ->
             repo().aggregate(
               from(r in RememberRequest, where: like(r.idempotency_key, ^"#{prefix}:%")),
               :count
             )
           end) == 12
  end

  test "concurrent independent requests retain every request and one shared typed source" do
    prefix = unique("independent-typed")
    cleanup_on_exit(prefix)
    source = session_evidence(prefix)

    results =
      concurrent_remember(12, fn n ->
        Memories.remember(
          "concurrent typed #{prefix}",
          direct_opts("#{prefix}:#{n}") ++ [evidence: [source]]
        )
      end)

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    memory_ids = Enum.map(results, fn {:ok, {:ok, memory}} -> memory.id end)
    assert [memory_id] = Enum.uniq(memory_ids)
    assert evidence_count(memory_ids) == 13

    assert unboxed(fn ->
             repo().aggregate(
               from(e in Evidence,
                 where:
                   e.memory_id == ^memory_id and e.source_session_id == ^prefix and
                     e.host_id == "source-host"
               ),
               :count
             )
           end) == 1
  end

  test "remember holding the candidate key-share lock makes hard delete retain provenance" do
    prefix = unique("remember-wins-delete-race")
    key = "#{prefix}:remember"
    lock_key = unique_lock_key()
    cleanup_on_exit(prefix)
    restore_hard_delete_on_exit()
    legacy = insert_legacy_memory!(prefix)
    install_request_gate!(prefix, key, lock_key)

    gate = hold_advisory_gate(lock_key)

    remember =
      Task.async(fn -> unboxed(fn -> Memories.remember(prefix, direct_opts(key)) end) end)

    wait_for_advisory_waiter!(lock_key)

    forget = Task.async(fn -> unboxed(fn -> Memories.trusted_forget(legacy.id) end) end)
    assert Task.yield(forget, 200) == nil

    release_advisory_gate(gate)

    assert {:ok, %Memory{id: memory_id}} = Task.await(remember, @timeout)
    assert memory_id == legacy.id
    assert {:error, :provenance_retained} = Task.await(forget, @timeout)
    assert evidence_count([legacy.id]) == 1
  end

  test "hard delete holding the row lock lets remember attach evidence to a valid replacement" do
    prefix = unique("delete-wins-remember-race")
    key = "#{prefix}:remember"
    lock_key = unique_lock_key()
    cleanup_on_exit(prefix)
    restore_hard_delete_on_exit()
    legacy = insert_legacy_memory!(prefix)
    install_delete_gate!(prefix, legacy.id, lock_key)

    gate = hold_advisory_gate(lock_key)
    forget = Task.async(fn -> unboxed(fn -> Memories.trusted_forget(legacy.id) end) end)
    wait_for_advisory_waiter!(lock_key)

    remember =
      Task.async(fn -> unboxed(fn -> Memories.remember(prefix, direct_opts(key)) end) end)

    assert Task.yield(remember, 200) == nil

    release_advisory_gate(gate)

    assert :ok = Task.await(forget, @timeout)
    assert {:ok, %Memory{id: replacement_id}} = Task.await(remember, @timeout)
    refute replacement_id == legacy.id
    assert evidence_count([replacement_id]) == 1

    assert {:ok, %Memory{id: ^replacement_id}} =
             unboxed(fn -> Memories.trusted_get(replacement_id) end)
  end

  defp concurrent_remember(count, fun) do
    1..count
    |> Task.async_stream(fn n -> unboxed(fn -> fun.(n) end) end,
      max_concurrency: count,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp evidence_count(memory_ids) do
    memory_id = hd(memory_ids)

    unboxed(fn ->
      repo().aggregate(from(e in Evidence, where: e.memory_id == ^memory_id), :count)
    end)
  end

  defp direct_opts(key) do
    [agent_id: "agent", host_id: "host", idempotency_scope: "direct", idempotency_key: key]
  end

  defp session_evidence(source_session_id) do
    %{
      source_session_id: source_session_id,
      host_id: "source-host",
      evidence_kind: "derives",
      support_score: 0.9
    }
  end

  defp insert_legacy_memory!(content) do
    unboxed(fn ->
      %Memory{}
      |> Memory.changeset(%{content: content, agent_id: "agent", host_id: "host"})
      |> repo().insert!()
    end)
  end

  defp restore_hard_delete_on_exit do
    key = "memory.hard_delete_enabled"
    previous = :ets.lookup(:backplane_settings, key)
    true = :ets.insert(:backplane_settings, {key, "true"})

    on_exit(fn ->
      case previous do
        [] -> :ets.delete(:backplane_settings, key)
        [entry] -> :ets.insert(:backplane_settings, entry)
      end
    end)
  end

  defp install_request_gate!(prefix, key, lock_key) do
    suffix = trigger_suffix(prefix)
    function = "bpm_test_request_gate_#{suffix}"
    trigger = "bpm_test_request_gate_#{suffix}"

    unboxed(fn ->
      repo().query!("""
      CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.idempotency_key = '#{key}' THEN
          PERFORM pg_advisory_xact_lock(#{lock_key});
        END IF;
        RETURN NEW;
      END;
      $$
      """)

      repo().query!("""
      CREATE TRIGGER #{trigger}
      BEFORE INSERT ON bpm_memory_remember_requests
      FOR EACH ROW EXECUTE FUNCTION #{function}()
      """)
    end)

    cleanup_trigger_on_exit("bpm_memory_remember_requests", trigger, function)
  end

  defp install_delete_gate!(prefix, memory_id, lock_key) do
    suffix = trigger_suffix(prefix)
    function = "bpm_test_delete_gate_#{suffix}"
    trigger = "bpm_test_delete_gate_#{suffix}"

    unboxed(fn ->
      repo().query!("""
      CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.id = '#{memory_id}'::uuid THEN
          PERFORM pg_advisory_xact_lock(#{lock_key});
        END IF;
        RETURN OLD;
      END;
      $$
      """)

      repo().query!("""
      CREATE TRIGGER #{trigger}
      BEFORE DELETE ON bpm_memories
      FOR EACH ROW EXECUTE FUNCTION #{function}()
      """)
    end)

    cleanup_trigger_on_exit("bpm_memories", trigger, function)
  end

  defp cleanup_trigger_on_exit(table, trigger, function) do
    on_exit(fn ->
      unboxed(fn ->
        repo().query!("DROP TRIGGER IF EXISTS #{trigger} ON #{table}")
        repo().query!("DROP FUNCTION IF EXISTS #{function}()")
      end)
    end)
  end

  defp hold_advisory_gate(lock_key) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          repo().transaction(fn ->
            repo().query!("SELECT pg_advisory_xact_lock($1::bigint)", [lock_key])
            send(parent, {:advisory_gate_locked, lock_key})

            receive do
              {:release_advisory_gate, ^lock_key} -> :ok
            after
              @timeout -> repo().rollback(:gate_timeout)
            end
          end)
        end)
      end)

    assert_receive {:advisory_gate_locked, ^lock_key}, @timeout
    {task, lock_key}
  end

  defp release_advisory_gate({task, lock_key}) do
    send(task.pid, {:release_advisory_gate, lock_key})
    assert {:ok, :ok} = Task.await(task, @timeout)
  end

  defp wait_for_advisory_waiter!(lock_key) do
    unboxed(fn -> wait_for_advisory_waiter!(lock_key, 100) end)
  end

  defp wait_for_advisory_waiter!(_lock_key, 0), do: flunk("advisory lock waiter did not appear")

  defp wait_for_advisory_waiter!(lock_key, attempts) do
    [[count]] =
      repo().query!(
        """
        SELECT count(*)
        FROM pg_locks
        WHERE locktype = 'advisory'
          AND classid = 0
          AND objid = $1
          AND objsubid = 1
          AND NOT granted
        """,
        [lock_key]
      ).rows

    if count > 0 do
      :ok
    else
      Process.sleep(20)
      wait_for_advisory_waiter!(lock_key, attempts - 1)
    end
  end

  defp unique_lock_key, do: rem(System.unique_integer([:positive, :monotonic]), 2_000_000_000)
  defp trigger_suffix(prefix), do: String.replace(prefix, "-", "_")

  defp unboxed(fun) do
    :ok = Sandbox.checkout(repo(), sandbox: false)

    try do
      fun.()
    after
      :ok = Sandbox.checkin(repo())
    end
  end

  defp cleanup_on_exit(prefix) do
    on_exit(fn ->
      unboxed(fn ->
        repo().query!("ALTER TABLE bpm_memory_evidence DISABLE TRIGGER USER")
        repo().query!("ALTER TABLE bpm_memory_remember_requests DISABLE TRIGGER USER")

        try do
          repo().query!(
            """
            DELETE FROM bpm_memory_evidence
            WHERE memory_id IN (
              SELECT id FROM bpm_memories WHERE content LIKE $1
            )
            """,
            ["%#{prefix}%"]
          )

          repo().query!(
            """
            DELETE FROM bpm_memory_remember_requests
            WHERE idempotency_key = $1 OR idempotency_key LIKE $2
            """,
            [prefix, "#{prefix}:%"]
          )

          repo().query!("DELETE FROM bpm_memories WHERE content LIKE $1", ["%#{prefix}%"])
        after
          repo().query!("ALTER TABLE bpm_memory_remember_requests ENABLE TRIGGER USER")
          repo().query!("ALTER TABLE bpm_memory_evidence ENABLE TRIGGER USER")
        end
      end)
    end)
  end

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)

  defp unique(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
