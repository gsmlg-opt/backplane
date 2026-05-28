defmodule Backplane.Repo.Migrations.CreateAgentMcpServers do
  use Ecto.Migration

  def change do
    create table(:agent_mcp_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all), null: true
      add :name, :string, null: false
      add :prefix, :string, null: false
      add :transport, :string, null: false, default: "http"
      add :url, :string
      add :command, :string
      add :args, {:array, :string}, default: []
      add :env, :map, default: %{}
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_mcp_servers, [:host_id, :prefix],
             name: :agent_mcp_servers_host_id_prefix_idx
           )

    create index(:agent_mcp_servers, [:host_id])
  end
end
