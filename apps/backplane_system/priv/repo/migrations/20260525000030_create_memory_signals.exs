defmodule Backplane.Repo.Migrations.CreateMemorySignals do
  use Ecto.Migration

  def change do
    create table(:memory_signals, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:sender_agent_id, :text, null: false)
      add(:recipient_agent_id, :text, null: false)
      add(:topic, :text, null: false)
      add(:payload, :map, null: false, default: %{})
      add(:sent_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:read_at, :utc_datetime_usec)
    end

    create(index(:memory_signals, [:recipient_agent_id, :read_at]))
  end
end
