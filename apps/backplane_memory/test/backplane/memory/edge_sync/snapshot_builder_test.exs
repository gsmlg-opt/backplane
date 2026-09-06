defmodule Backplane.Memory.EdgeSync.SnapshotTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.EdgeSync.SnapshotBuilderTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Backplane.Memory.EdgeSync.{SnapshotBuilder, SnapshotChunk, PostgresStore}
  alias Backplane.Memory.EdgeSync.SnapshotTestRepo, as: Repo

  setup do
    previous = Application.fetch_env!(:backplane_memory, :repo)
    config = previous.config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 6)
    start_supervised!({Repo, config})
    Application.put_env(:backplane_memory, :repo, Repo)
    space = Ecto.UUID.generate()
    p = %{memory_space_id: space, scope: "snapshot-test", namespace: "private"}

    Repo.query!(
      "INSERT INTO bpm_memory_spaces (id,kind,status,inserted_at,updated_at) VALUES ($1,'private','active',now(),now())",
      [Ecto.UUID.dump!(space)]
    )

    Repo.query!(
      "INSERT INTO bpm_memory_space_entitlements (memory_space_id,host_id,scope,namespace,status,inserted_at,updated_at) VALUES ($1,$2,$3,'private','active',now(),now())",
      [Ecto.UUID.dump!(space), Ecto.UUID.dump!(Ecto.UUID.generate()), p.scope]
    )

    on_exit(fn ->
      Application.put_env(:backplane_memory, :repo, previous)
      {:ok, pid} = Repo.start_link(config)

      for table <-
            ~w(bpm_memories bpm_memory_snapshots bpm_memory_changes bpm_memory_partition_revisions bpm_memory_space_entitlements bpm_memory_spaces) do
        column = if table == "bpm_memory_spaces", do: "id", else: "memory_space_id"
        Repo.query!("DELETE FROM #{table} WHERE #{column}=$1", [Ecto.UUID.dump!(space)])
      end

      GenServer.stop(pid)
    end)

    %{partition: p}
  end

  test "canonical snapshots survive missing history, sort IDs and hash bounded chunks deterministically",
       %{partition: p} do
    ids = for n <- 1..5, do: insert(p, "unchanged #{n}")

    Repo.query!("DELETE FROM bpm_memory_changes WHERE memory_space_id=$1", [
      Ecto.UUID.dump!(p.memory_space_id)
    ])

    limits = %{max_changes: 2, max_frame_bytes: 2200}
    assert {:ok, first} = Repo.transaction(fn -> SnapshotBuilder.build_locked(p, limits) end)
    assert first.revision == 5

    chunks =
      Repo.all(
        from(c in SnapshotChunk, where: c.snapshot_id == ^first.id, order_by: c.chunk_index)
      )

    assert length(chunks) == 3

    assert Enum.flat_map(chunks, fn c -> Enum.map(c.payload["items"], & &1["canonical_id"]) end) ==
             Enum.sort(ids)

    for c <- chunks do
      assert c.item_count <= 2
      assert c.chunk_hash == SnapshotBuilder.hash(c.payload)
      assert PostgresStore.bytes(SnapshotBuilder.frame(first, c, Ecto.UUID.generate())) <= 2200
    end

    assert {:ok, second} = Repo.transaction(fn -> SnapshotBuilder.build_locked(p, limits) end)
    assert first.integrity_hash == second.integrity_hash
  end

  test "empty canonical snapshot has one empty verifiable chunk", %{partition: p} do
    {:ok, snapshot} =
      Repo.transaction(fn ->
        SnapshotBuilder.build_locked(p, %{max_changes: 1, max_frame_bytes: 2000})
      end)

    assert snapshot.item_count == 0
    assert snapshot.chunk_count == 1
    chunk = Repo.one!(from(c in SnapshotChunk, where: c.snapshot_id == ^snapshot.id))
    assert chunk.payload == %{"items" => []}
    assert chunk.chunk_hash == SnapshotBuilder.hash(chunk.payload)
  end

  test "concurrent canonical mutation cannot cross captured revision during snapshot materialization",
       %{partition: p} do
    id = insert(p, "before mutation")
    suffix = System.unique_integer([:positive])
    function = "snapshot_pause_#{suffix}"
    trigger = "snapshot_pause_#{suffix}"
    key = suffix

    Repo.query!(
      "CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF EXISTS(SELECT 1 FROM bpm_memory_snapshots WHERE id=NEW.snapshot_id AND memory_space_id='#{p.memory_space_id}'::uuid) THEN PERFORM pg_advisory_xact_lock(#{key}); END IF; RETURN NEW; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER #{trigger} BEFORE INSERT ON bpm_memory_snapshot_chunks FOR EACH ROW EXECUTE FUNCTION #{function}()"
    )

    try do
      parent = self()

      blocker =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
            send(parent, :blocked)

            receive do
              :release -> :ok
            after
              5000 -> raise "release timeout"
            end
          end)
        end)

      assert_receive :blocked

      builder =
        Task.async(fn ->
          Repo.transaction(fn ->
            SnapshotBuilder.build_locked(p, %{max_changes: 1, max_frame_bytes: 2000})
          end)
        end)

      wait_for_lock("advisory")

      mutator =
        Task.async(fn ->
          Repo.query!("UPDATE bpm_memories SET content='after mutation' WHERE id=$1", [
            Ecto.UUID.dump!(id)
          ])
        end)

      wait_for_lock("transactionid")
      refute Task.yield(mutator, 20)
      send(blocker.pid, :release)
      assert {:ok, :ok} = Task.await(blocker)
      assert {:ok, snapshot} = Task.await(builder)
      Task.await(mutator)
      assert snapshot.revision == 1
      chunk = Repo.one!(from(c in SnapshotChunk, where: c.snapshot_id == ^snapshot.id))
      assert [%{"content" => "before mutation"}] = chunk.payload["items"]

      assert [[2]] =
               Repo.query!(
                 "SELECT current_revision FROM bpm_memory_partition_revisions WHERE memory_space_id=$1",
                 [Ecto.UUID.dump!(p.memory_space_id)]
               ).rows

      assert [["after mutation"]] =
               Repo.query!("SELECT content FROM bpm_memories WHERE id=$1", [Ecto.UUID.dump!(id)]).rows
    after
      Repo.query!("DROP TRIGGER #{trigger} ON bpm_memory_snapshot_chunks")
      Repo.query!("DROP FUNCTION #{function}()")
    end
  end

  defp wait_for_lock(event, attempts \\ 100)
  defp wait_for_lock(_, 0), do: flunk("concurrent transaction did not reach expected lock")

  defp wait_for_lock(event, attempts) do
    case Repo.query!(
           "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event=$1",
           [event]
         ).rows do
      [[n]] when n > 0 ->
        :ok

      _ ->
        Process.sleep(10)
        wait_for_lock(event, attempts - 1)
    end
  end

  defp insert(p, content) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO bpm_memories (id,memory_space_id,host_id,client_id,scope,namespace,agent_id,content,content_hash,memory_type,lifecycle_state,inserted_at,updated_at) VALUES ($1,$2,'snapshot-test','snapshot-test',$3,'private','test',$4,$5,'semantic','active',now(),now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(p.memory_space_id),
        p.scope,
        content,
        :crypto.hash(:sha256, content)
      ]
    )

    id
  end
end
