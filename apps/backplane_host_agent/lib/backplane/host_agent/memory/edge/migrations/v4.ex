defmodule Backplane.HostAgent.Memory.Edge.Migrations.V4 do
  @moduledoc false
  def version, do: 4

  def up do
    [
      "ALTER TABLE edge_partitions ADD COLUMN access_id TEXT",
      "ALTER TABLE edge_partitions ADD COLUMN authority_version INTEGER"
    ]
  end
end
