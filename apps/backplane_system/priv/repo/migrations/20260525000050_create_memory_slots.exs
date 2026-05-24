defmodule Backplane.Repo.Migrations.CreateMemorySlots do
  use Ecto.Migration

  def up do
    create table(:memory_slots, primary_key: false) do
      add(:name, :text, primary_key: true)
      add(:content, :text, null: false, default: "")
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:updated_by, :text)
      add(:size_limit_chars, :integer, null: false, default: 2000)
    end

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    slots =
      ~w(persona user_preferences tool_guidelines project_context guidance pending_items session_patterns self_notes)

    Enum.each(slots, fn name ->
      execute(
        "INSERT INTO memory_slots (name, content, updated_at) VALUES ('#{name}', '', '#{now}') ON CONFLICT (name) DO NOTHING"
      )
    end)
  end

  def down do
    drop_if_exists(table(:memory_slots))
  end
end
