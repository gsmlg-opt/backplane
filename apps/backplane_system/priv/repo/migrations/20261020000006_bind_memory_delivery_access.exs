defmodule Backplane.Repo.Migrations.BindMemoryDeliveryAccess do
  use Ecto.Migration

  def up do
    for table <- [:bpm_host_memory_cursors, :bpm_host_memory_deliveries] do
      alter table(table, prefix: prefix()) do
        add(:access_id, :binary_id)
        add(:authority_version, :bigint)
      end

      create constraint(table, "#{table}_access_shape",
               prefix: prefix(),
               check:
                 "(access_id IS NULL AND authority_version IS NULL) OR (access_id IS NOT NULL AND authority_version IS NOT NULL AND authority_version > 0)"
             )
    end
  end
end
