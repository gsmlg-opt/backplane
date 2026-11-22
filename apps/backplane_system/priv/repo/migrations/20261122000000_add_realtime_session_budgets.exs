defmodule Backplane.Repo.Migrations.AddRealtimeSessionBudgets do
  use Ecto.Migration

  def up do
    alter table(:llm_openai_services) do
      add :realtime_max_input_bytes, :integer, default: 536_870_912
      add :realtime_max_output_bytes, :integer, default: 536_870_912
    end

    flush()

    execute("""
    UPDATE "#{prefix() || "public"}".llm_openai_services
    SET realtime_max_input_bytes = max_request_bytes,
        realtime_max_output_bytes = max_response_bytes
    WHERE kind = 'realtime'
    """)

    create constraint(:llm_openai_services, :llm_openai_services_realtime_input_budget_check,
             check:
               "kind <> 'realtime' OR (realtime_max_input_bytes IS NOT NULL AND realtime_max_input_bytes > 0)"
           )

    create constraint(:llm_openai_services, :llm_openai_services_realtime_output_budget_check,
             check:
               "kind <> 'realtime' OR (realtime_max_output_bytes IS NOT NULL AND realtime_max_output_bytes > 0)"
           )
  end

  def down do
    drop constraint(:llm_openai_services, :llm_openai_services_realtime_input_budget_check)
    drop constraint(:llm_openai_services, :llm_openai_services_realtime_output_budget_check)

    alter table(:llm_openai_services) do
      remove :realtime_max_input_bytes
      remove :realtime_max_output_bytes
    end
  end
end
