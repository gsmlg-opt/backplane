defmodule Backplane.Repo.Migrations.RealtimeBudgetTestRepo do
  use Ecto.Repo, otp_app: :backplane_system, adapter: Ecto.Adapters.Postgres
end

defmodule Backplane.Repo.Migrations.AddRealtimeSessionBudgetsTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo.Migrations.AddRealtimeSessionBudgets, as: Migration
  alias Backplane.Repo.Migrations.RealtimeBudgetTestRepo

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20261122000000_add_realtime_session_budgets.exs",
                    __DIR__
                  )
  @version 20_261_122_000_000

  setup do
    Code.require_file(@migration_path)
    config = Backplane.Repo.config() |> Keyword.delete(:pool) |> Keyword.put(:pool_size, 2)
    start_supervised!({RealtimeBudgetTestRepo, config})
    prefix = "realtime_budget_#{System.unique_integer([:positive])}"
    RealtimeBudgetTestRepo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    RealtimeBudgetTestRepo.query!("""
    CREATE TABLE "#{prefix}".llm_openai_services (
      id serial PRIMARY KEY,
      kind text NOT NULL,
      max_request_bytes integer NOT NULL DEFAULT 50000000,
      max_response_bytes integer NOT NULL DEFAULT 100000000
    )
    """)

    on_exit(fn ->
      {:ok, pid} = RealtimeBudgetTestRepo.start_link(config)
      RealtimeBudgetTestRepo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|)
      Supervisor.stop(pid)
    end)

    %{prefix: prefix}
  end

  test "migration preserves every existing Realtime policy and defaults only new services", %{
    prefix: prefix
  } do
    RealtimeBudgetTestRepo.query!("""
    INSERT INTO "#{prefix}".llm_openai_services (kind, max_request_bytes, max_response_bytes)
    VALUES ('realtime', 50000000, 100000000), ('realtime', 123, 456), ('speech', 12, 34)
    """)

    assert :ok =
             Ecto.Migrator.up(RealtimeBudgetTestRepo, @version, Migration,
               prefix: prefix,
               log: false
             )

    assert [
             ["realtime", 50_000_000, 100_000_000],
             ["realtime", 123, 456],
             ["speech", 536_870_912, 536_870_912]
           ] =
             RealtimeBudgetTestRepo.query!("""
             SELECT kind, realtime_max_input_bytes, realtime_max_output_bytes
             FROM "#{prefix}".llm_openai_services ORDER BY id
             """).rows

    assert [[536_870_912, 536_870_912, 50_000_000, 100_000_000]] =
             RealtimeBudgetTestRepo.query!("""
             INSERT INTO "#{prefix}".llm_openai_services (kind) VALUES ('realtime')
             RETURNING realtime_max_input_bytes, realtime_max_output_bytes, max_request_bytes, max_response_bytes
             """).rows

    for field <- ["realtime_max_input_bytes", "realtime_max_output_bytes"],
        value <- ["NULL", "0", "-1"] do
      assert_raise Postgrex.Error, ~r/realtime_.*_budget_check/, fn ->
        RealtimeBudgetTestRepo.query!("""
        INSERT INTO "#{prefix}".llm_openai_services (kind, #{field}) VALUES ('realtime', #{value})
        """)
      end
    end

    RealtimeBudgetTestRepo.query!("""
    INSERT INTO "#{prefix}".llm_openai_services (kind, realtime_max_input_bytes, realtime_max_output_bytes)
    VALUES ('speech', NULL, NULL)
    """)

    assert :ok =
             Ecto.Migrator.down(RealtimeBudgetTestRepo, @version, Migration,
               prefix: prefix,
               log: false
             )

    assert [
             [50_000_000, 100_000_000],
             [123, 456],
             [12, 34],
             [50_000_000, 100_000_000],
             [50_000_000, 100_000_000]
           ] =
             RealtimeBudgetTestRepo.query!("""
             SELECT max_request_bytes, max_response_bytes FROM "#{prefix}".llm_openai_services ORDER BY id
             """).rows
  end
end
