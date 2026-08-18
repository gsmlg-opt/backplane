defmodule Backplane.Repo.Migrations.AddProtocolVersionToMcpUpstreams do
  use Ecto.Migration

  def change do
    alter table(:mcp_upstreams) do
      add :protocol_version, :string, null: false, default: "2025-11-25"
    end
  end
end
