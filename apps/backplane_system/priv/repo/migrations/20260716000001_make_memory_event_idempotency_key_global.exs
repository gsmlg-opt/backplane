defmodule Backplane.Repo.Migrations.MakeMemoryEventIdempotencyKeyGlobal do
  use Ecto.Migration

  def up do
    events_table =
      case prefix() do
        nil -> "bpm_events"
        prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".bpm_events)
      end

    collision_query =
      "SELECT idempotency_key, array_agg(DISTINCT stream_id ORDER BY stream_id) AS stream_ids, " <>
        "count(*) AS event_count FROM #{events_table} WHERE idempotency_key IS NOT NULL " <>
        "GROUP BY idempotency_key HAVING count(DISTINCT stream_id) > 1;"

    execute("""
    DO $preflight$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{events_table}
        WHERE idempotency_key IS NOT NULL
        GROUP BY idempotency_key
        HAVING count(DISTINCT stream_id) > 1
      ) THEN
        RAISE EXCEPTION USING
          ERRCODE = '23505',
          MESSAGE = 'Cannot make bpm_events.idempotency_key globally unique: non-null keys occur in multiple streams.',
          HINT = 'Identify collisions with: #{collision_query} Resolve each collision by operator review and repair historical rows only after deciding which event is authoritative, then retry this migration; no rows are changed automatically.';
      END IF;
    END
    $preflight$;
    """)

    drop index(:bpm_events, [:stream_id, :idempotency_key],
           name: :bpm_events_idempotency_key_uniq
         )

    create unique_index(:bpm_events, [:idempotency_key],
             name: :bpm_events_idempotency_key_uniq,
             where: "idempotency_key IS NOT NULL"
           )
  end

  def down do
    drop index(:bpm_events, [:idempotency_key], name: :bpm_events_idempotency_key_uniq)

    create unique_index(:bpm_events, [:stream_id, :idempotency_key],
             name: :bpm_events_idempotency_key_uniq,
             where: "idempotency_key IS NOT NULL"
           )
  end
end
