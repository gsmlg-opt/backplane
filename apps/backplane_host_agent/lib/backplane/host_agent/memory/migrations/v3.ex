defmodule Backplane.HostAgent.Memory.Migrations.V3 do
  @moduledoc false

  def version, do: 3

  def up do
    [
      "ALTER TABLE memories ADD COLUMN remote_revision INTEGER CHECK (remote_revision IS NULL OR remote_revision > 0)"
    ]
  end
end
