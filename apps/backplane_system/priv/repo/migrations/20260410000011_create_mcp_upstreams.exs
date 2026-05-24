defmodule Backplane.Repo.Migrations.CreateMcpUpstreams do
  use Ecto.Migration

  def change do
    create table(:mcp_upstreams, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :prefix, :text, null: false
      add :transport, :text, null: false
      add :url, :text
      add :command, :text
      add :args, {:array, :text}, default: []
      add :credential, :text
      add :timeout_ms, :integer, default: 30000
      add :refresh_interval_ms, :integer, default: 300000
      add :enabled, :boolean, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_upstreams, [:name])
    create unique_index(:mcp_upstreams, [:prefix])
  end
end
