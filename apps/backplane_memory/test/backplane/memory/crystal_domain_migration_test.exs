defmodule Backplane.Memory.CrystalDomainMigrationTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Memory.CrystalDomainMigrationTest do
  use Backplane.Memory.DataCase, async: false

  @version 20_260_812_000_016
  @migration Backplane.Repo.Migrations.AddCrystalActionAndLessonProvenance

  test "00016 migrates a non-public schema up and down without touching public objects" do
    prefix = "crystal_domain_#{System.unique_integer([:positive])}"
    repo = Backplane.Memory.CrystalDomainMigrationTestRepo
    start_supervised!({repo, Application.fetch_env!(:backplane_system, Backplane.Repo)})

    Code.require_file(
      Application.app_dir(
        :backplane_system,
        "priv/repo/migrations/20260812000016_add_crystal_action_and_lesson_provenance.exs"
      )
    )

    public_oid = oid(repo, "public.memory_crystal_source_actions")
    repo.query!(~s(CREATE SCHEMA "#{prefix}"))

    try do
      prerequisites(repo, prefix)
      assert :ok = Ecto.Migrator.up(repo, @version, @migration, prefix: prefix, log: false)
      assert oid(repo, "#{prefix}.memory_crystal_source_actions")
      assert oid(repo, "public.memory_crystal_source_actions") == public_oid
      assert :ok = Ecto.Migrator.down(repo, @version, @migration, prefix: prefix, log: false)
      refute oid(repo, "#{prefix}.memory_crystal_source_actions")
      assert oid(repo, "public.memory_crystal_source_actions") == public_oid
    after
      repo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end
  end

  defp prerequisites(repo, prefix) do
    q = &~s("#{prefix}".#{&1})

    repo.query!(
      "CREATE TABLE #{q.("bpm_memories")} (id uuid PRIMARY KEY, host_id text, client_id text, scope text, namespace text)"
    )

    repo.query!(
      "CREATE TABLE #{q.("memory_actions")} (id uuid PRIMARY KEY, status text, host_id text, client_id text, scope text, namespace text)"
    )

    repo.query!(
      "CREATE TABLE #{q.("memory_lessons")} (memory_id uuid PRIMARY KEY REFERENCES #{q.("bpm_memories")}(id))"
    )

    repo.query!(
      "CREATE TABLE #{q.("memory_crystals")} (id uuid PRIMARY KEY, client_id text, scope text, namespace text, host_id text, processing_version text)"
    )

    repo.query!(
      "CREATE TABLE #{q.("memory_crystal_lessons")} (crystal_id uuid, lesson_memory_id uuid, relation_type text, inserted_at timestamp, PRIMARY KEY(crystal_id, lesson_memory_id))"
    )

    repo.query!(
      "CREATE TABLE #{q.("bpm_memory_evidence")} (id uuid PRIMARY KEY, memory_id uuid REFERENCES #{q.("bpm_memories")}(id), source_event_id uuid, source_observation_id uuid, source_summary_id uuid, source_request_id uuid, source_session_id text, host_id text, CONSTRAINT bpm_memory_evidence_source_check CHECK (num_nonnulls(source_event_id, source_observation_id, source_summary_id, source_request_id) + CASE WHEN source_session_id IS NULL THEN 0 ELSE 1 END = 1))"
    )
  end

  defp oid(repo, name) do
    case repo.query!("SELECT to_regclass($1)::oid", [name]).rows do
      [[nil]] -> nil
      [[value]] -> value
    end
  end
end
