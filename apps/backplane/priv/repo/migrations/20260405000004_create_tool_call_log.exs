defmodule Backplane.Repo.Migrations.CreateToolCallLog do
  use Ecto.Migration

  def change do
    create table(:tool_call_log) do
      add(:tool_name, :text, null: false)
      add(:client_id, references(:clients, type: :uuid, on_delete: :nilify_all))
      add(:client_name, :text)
      add(:duration_us, :bigint)
      add(:status, :text, null: false)
      add(:error_message, :text)
      add(:arguments_hash, :text)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:tool_call_log, [:tool_name]))
    create(index(:tool_call_log, [:client_id]))
    create(index(:tool_call_log, [:inserted_at]))
  end
end
