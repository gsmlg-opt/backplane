defmodule Backplane.HostAgent.TursoSpikeTest do
  use ExUnit.Case, async: false

  alias Turso.Result

  @moduletag :tmp_dir

  test "retains the v1 LIKE recall baseline without SQLite FTS5", %{tmp_dir: tmp_dir} do
    db = start_db!(tmp_dir)

    assert {:error, %Turso.Error{message: message}} =
             Turso.execute(db, "CREATE VIRTUAL TABLE memories_fts USING fts5(content)")

    assert message =~ "no such module: fts5"

    # ex_turso 3 supports Turso-native FTS indexes, but adopting them requires
    # a separate host-memory schema/query migration.
    assert {:ok, _} =
             Turso.execute(db, """
             CREATE TABLE memories (
               id INTEGER PRIMARY KEY,
               content TEXT NOT NULL
             )
             """)

    assert {:ok, _} =
             Turso.execute(db, "INSERT INTO memories(id, content) VALUES (?, ?)", [
               1,
               "local semantic recall baseline"
             ])

    assert {:ok, _} =
             Turso.execute(db, "INSERT INTO memories(id, content) VALUES (?, ?)", [
               2,
               "unrelated context"
             ])

    assert {:ok,
            %Result{
              rows: [
                %{"content" => "local semantic recall baseline", "source" => "local_like"}
              ]
            }} =
             Turso.query(
               db,
               "SELECT content, 'local_like' AS source FROM memories WHERE content LIKE ?",
               ["%semantic%"]
             )
  end

  test "uses WAL and busy_timeout under pooled concurrent writers", %{tmp_dir: tmp_dir} do
    db = start_db!(tmp_dir, pool_size: 5)

    assert {:ok, %Result{rows: [%{"journal_mode" => mode}]}} =
             Turso.query(db, "PRAGMA journal_mode = WAL")

    assert String.downcase(mode) == "wal"

    assert {:ok, _} =
             Turso.execute(db, "CREATE TABLE writes (id INTEGER PRIMARY KEY, note TEXT)")

    writer_count = 8

    results =
      1..writer_count
      |> Task.async_stream(
        fn id ->
          :timer.tc(fn ->
            DBConnection.transaction(
              db,
              fn conn ->
                {:ok, _} = Turso.execute(conn, "PRAGMA busy_timeout = 5000")

                {:ok, _} =
                  Turso.execute(conn, "INSERT INTO writes(id, note) VALUES (?, ?)", [
                    id,
                    "writer #{id}"
                  ])

                Process.sleep(20)
                :ok
              end,
              timeout: 10_000
            )
          end)
        end,
        max_concurrency: 5,
        timeout: 20_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {_micros, {:ok, :ok}}} -> true
             _ -> false
           end)

    durations = for {:ok, {micros, _result}} <- results, do: micros
    assert Enum.max(durations) > 0

    assert {:ok, %Result{rows: [%{"count" => ^writer_count}]}} =
             Turso.query(db, "SELECT COUNT(*) AS count FROM writes")
  end

  test "rolls back DBConnection transactions", %{tmp_dir: tmp_dir} do
    db = start_db!(tmp_dir)

    assert {:ok, _} =
             Turso.execute(db, "CREATE TABLE users (id INTEGER PRIMARY KEY, score INTEGER)")

    assert {:ok, _} = Turso.execute(db, "INSERT INTO users VALUES (?, ?)", [1, 10])

    assert {:error, :rollback_check} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 Turso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [99, 1])

               DBConnection.rollback(conn, :rollback_check)
             end)

    assert {:ok, %Result{rows: [%{"score" => 10}]}} =
             Turso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end

  test "round-trips JSON text through a JSON column", %{tmp_dir: tmp_dir} do
    db = start_db!(tmp_dir)
    payload = %{"scope" => "proj_local", "tags" => ["host", "memory"], "confidence" => 0.9}
    json = Jason.encode!(payload)

    assert {:ok, _} =
             Turso.execute(db, "CREATE TABLE documents (id INTEGER PRIMARY KEY, payload JSON)")

    assert {:ok, _} = Turso.execute(db, "INSERT INTO documents VALUES (?, ?)", [1, json])

    assert {:ok, %Result{rows: [%{"payload" => ^json, "scope" => "proj_local"}]}} =
             Turso.query(
               db,
               "SELECT payload, json_extract(payload, '$.scope') AS scope FROM documents WHERE id = ?",
               [1]
             )

    assert Jason.decode!(json) == payload
  end

  test "dedup-hit path supports partial unique index with ON CONFLICT DO NOTHING", %{
    tmp_dir: tmp_dir
  } do
    db = start_db!(tmp_dir)

    assert {:ok, _} =
             Turso.execute(db, """
             CREATE TABLE memories (
               id TEXT PRIMARY KEY,
               content_hash TEXT NOT NULL,
               scope TEXT NOT NULL,
               deleted_at TEXT
             )
             """)

    assert {:ok, _} =
             Turso.execute(db, """
             CREATE UNIQUE INDEX memories_content_hash_scope_uniq
             ON memories(content_hash, scope)
             WHERE deleted_at IS NULL
             """)

    insert_sql = """
    INSERT INTO memories(id, content_hash, scope, deleted_at)
    VALUES (?, ?, ?, NULL)
    ON CONFLICT DO NOTHING
    """

    assert {:ok, %Result{num_rows: 1}} =
             Turso.execute(db, insert_sql, ["mem_1", "hash_1", "proj_local"])

    assert {:ok, %Result{num_rows: 0}} =
             Turso.execute(db, insert_sql, ["mem_2", "hash_1", "proj_local"])

    assert {:ok, %Result{rows: [%{"id" => "mem_1", "count" => 1}]}} =
             Turso.query(
               db,
               """
               SELECT min(id) AS id, COUNT(*) AS count
               FROM memories
               WHERE content_hash = ? AND scope = ? AND deleted_at IS NULL
               """,
               ["hash_1", "proj_local"]
             )
  end

  defp start_db!(tmp_dir, opts \\ []) do
    name = :"host_agent_turso_spike_#{System.unique_integer([:positive])}"
    db_path = Path.join(tmp_dir, "#{name}.db")

    start_supervised!({Turso, Keyword.merge([database: db_path, name: name, pool_size: 1], opts)})

    name
  end
end
