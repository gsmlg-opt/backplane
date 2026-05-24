defmodule Backplane.Repo.Migrations.AddSseFieldsToMcpUpstreams do
  use Ecto.Migration

  def change do
    alter table(:mcp_upstreams) do
      add :headers, :map, default: %{}
      add :auth_scheme, :string, default: "none"
      add :auth_header_name, :string
    end
  end
end
