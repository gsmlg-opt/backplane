defmodule Backplane.Repo.Migrations.IndexExactPartitionMemoryActivity do
  use Ecto.Migration

  def change do
    create(
      index(
        :memory_activity_daily,
        [:host_id, :client_id, :scope, :namespace, :date, :project, :agent_id, :event_type],
        name: :memory_activity_daily_exact_partition_idx
      )
    )

    create(
      index(
        :memory_activity_subject_contributions,
        [
          :host_id,
          :client_id,
          :scope,
          :namespace,
          :date,
          :project,
          :agent_id,
          :event_type,
          :subject_id
        ],
        name: :memory_activity_contributions_exact_partition_idx
      )
    )

    create(
      index(
        :bpm_events,
        [
          :host_id,
          :client_id,
          :scope,
          :namespace,
          "occurred_at DESC",
          "id DESC"
        ],
        name: :bpm_events_activity_exact_partition_idx,
        where: "schema_version IS NOT NULL"
      )
    )
  end
end
