defmodule Backplane.Memory.RuntimeRetirementMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.RuntimeRetirementMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @migration Backplane.Repo.Migrations.RetireMemoryRuntimeSelectors
  @version 20_261_026_000_001

  test "converts provable jobs, reports unresolved authority, and preserves completed history" do
    with_schema(fn db, schema ->
      session_id = "canonical-session"
      space = Ecto.UUID.generate()
      summary = Ecto.UUID.generate()

      db.query!(
        """
        INSERT INTO "#{schema}".bpm_projected_sessions
          (session_id, host_id, client_id, memory_space_id, scope, namespace, input_revision)
        VALUES ($1, 'host-a', 'host:host-a', $2, 'global', 'private', 'revision')
        """,
        [session_id, Ecto.UUID.dump!(space)]
      )

      db.query!(
        """
        INSERT INTO "#{schema}".memory_summaries
          (id, session_id, processing_version, memory_space_id, host_id, scope, namespace)
        VALUES ($1, $2, 'summary-v1', $3, 'host-a', 'global', 'private')
        """,
        [Ecto.UUID.dump!(summary), session_id, Ecto.UUID.dump!(space)]
      )

      insert_job(db, schema, 1, "BackplaneMemory.Workers.SummaryWorker", %{
        "session_id" => session_id
      })

      insert_job(db, schema, 2, "BackplaneMemory.Workers.EpisodicWorker", %{
        "session_id" => session_id
      })

      insert_job(db, schema, 3, "Backplane.Memory.Workers.SummaryWorker", %{
        "session_id" => "unknown"
      })

      insert_job(db, schema, 4, "BackplaneMemory.Workers.EmbedWorker", %{"id" => space})

      insert_job(
        db,
        schema,
        5,
        "BackplaneMemory.Workers.SummaryWorker",
        %{"session_id" => "history"},
        "completed"
      )

      insert_job(
        db,
        schema,
        6,
        "BackplaneMemory.Workers.EmbedWorker",
        %{"id" => space},
        "suspended"
      )

      insert_job(
        db,
        schema,
        7,
        "BackplaneMemory.Workers.SummaryWorker",
        %{"session_id" => "unknown-suspended"},
        "suspended"
      )

      db.query!(
        ~s|INSERT INTO "#{schema}".system_settings VALUES ('memory.events.dual_write'), ('memory.recall_v2.enabled'), ('memory.pipeline.enabled')|
      )

      migrate(db, schema, @version)

      assert [["Backplane.Memory.Workers.SummaryWorker", "available", args, meta]] =
               job(db, schema, 1)

      assert args["host_id"] == "host-a"
      assert args["client_id"] == "host:host-a"
      assert args["memory_space_id"] == space
      assert args["input_revision"] == "revision"

      assert meta["memory_retirement"]["original_worker"] ==
               "BackplaneMemory.Workers.SummaryWorker"

      assert [
               [
                 "Backplane.Memory.Workers.EpisodicWorker",
                 "available",
                 %{"summary_id" => ^summary},
                 _
               ]
             ] = job(db, schema, 2)

      assert [
               [
                 _,
                 "cancelled",
                 %{"session_id" => "unknown"},
                 %{"memory_retirement" => %{"reason" => "unresolvable_canonical_authority"}}
               ]
             ] = job(db, schema, 3)

      assert [["Backplane.Memory.Workers.EmbedWorker", "available", %{"id" => ^space}, _]] =
               job(db, schema, 4)

      assert [
               [
                 "BackplaneMemory.Workers.SummaryWorker",
                 "completed",
                 %{"session_id" => "history"},
                 %{}
               ]
             ] = job(db, schema, 5)

      assert [["Backplane.Memory.Workers.EmbedWorker", "suspended", %{"id" => ^space}, _]] =
               job(db, schema, 6)

      assert [["Backplane.Memory.Workers.SummaryWorker", "cancelled", _, meta]] =
               job(db, schema, 7)

      assert meta["memory_retirement"]["reason"] == "unresolvable_canonical_authority"

      assert [["memory.pipeline.enabled"]] =
               db.query!(~s|SELECT key FROM "#{schema}".system_settings|).rows

      before = db.query!(~s|SELECT * FROM "#{schema}".styx_jobs ORDER BY id|).rows
      migrate(db, schema, @version + 1)
      assert before == db.query!(~s|SELECT * FROM "#{schema}".styx_jobs ORDER BY id|).rows
    end)
  end

  test "refuses to replace the identity of an executing legacy worker" do
    with_schema(fn db, schema ->
      insert_job(db, schema, 1, "BackplaneMemory.Workers.EmbedWorker", %{}, "executing")

      assert_raise Postgrex.Error, ~r/Stop Memory workers/, fn ->
        migrate(db, schema, @version)
      end

      assert [["BackplaneMemory.Workers.EmbedWorker", "executing", %{}, %{}]] = job(db, schema, 1)
    end)
  end

  defp insert_job(db, schema, id, worker, args, state \\ "available") do
    db.query!(
      ~s|INSERT INTO "#{schema}".styx_jobs (id, worker, args, state) VALUES ($1, $2, $3, $4)|,
      [id, worker, args, state]
    )
  end

  defp job(db, schema, id),
    do:
      db.query!(~s|SELECT worker, state, args, meta FROM "#{schema}".styx_jobs WHERE id = $1|, [
        id
      ]).rows

  defp migrate(db, schema, version) do
    Code.require_file(
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20261026000001_retire_memory_runtime_selectors.exs"
      )
    )

    assert :ok = Ecto.Migrator.up(db, version, @migration, prefix: schema, log: false)
  end

  defp with_schema(fun) do
    config = repo().config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    db = Backplane.Memory.RuntimeRetirementMigrationTestRepo
    start_supervised!({db, config})
    schema = "runtime_retirement_#{System.unique_integer([:positive])}"
    db.query!(~s|CREATE SCHEMA "#{schema}"|)

    try do
      db.query!(
        ~s|CREATE TABLE "#{schema}".styx_jobs (id bigint PRIMARY KEY, worker text, state text, args jsonb, meta jsonb NOT NULL DEFAULT '{}', cancelled_at timestamptz)|
      )

      db.query!(
        ~s|CREATE TABLE "#{schema}".bpm_projected_sessions (session_id text, host_id text, client_id text, source_client_id text, memory_space_id uuid, scope text, namespace text, input_revision text)|
      )

      db.query!(
        ~s|CREATE TABLE "#{schema}".memory_summaries (id uuid, session_id text, processing_version text, memory_space_id uuid, host_id text, scope text, namespace text, superseded_at timestamptz)|
      )

      db.query!(~s|CREATE TABLE "#{schema}".system_settings (key text PRIMARY KEY)|)
      fun.(db, schema)
    after
      db.query!(~s|DROP SCHEMA "#{schema}" CASCADE|)
    end
  end
end
