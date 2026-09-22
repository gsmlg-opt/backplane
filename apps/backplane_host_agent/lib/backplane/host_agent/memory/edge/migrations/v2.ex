defmodule Backplane.HostAgent.Memory.Edge.Migrations.V2 do
  @moduledoc false

  def version, do: 2

  def up do
    [
      "ALTER TABLE edge_partitions ADD COLUMN sync_status TEXT",
      "ALTER TABLE edge_partitions ADD COLUMN last_delivery_hash TEXT"
    ]
  end
end
