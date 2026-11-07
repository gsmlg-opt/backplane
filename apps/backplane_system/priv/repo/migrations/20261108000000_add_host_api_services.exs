defmodule Backplane.Repo.Migrations.AddHostApiServices do
  use Ecto.Migration

  def change do
    create table(:host_api_services, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :host_id, references(:skill_hosts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :endpoints, :map, null: false, default: %{}
      add :revision, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:host_api_services, [:host_id, :name])

    for table <- [:llm_providers, :embedding_providers] do
      alter table(table) do
        add :host_service_id,
            references(:host_api_services, type: :binary_id, on_delete: :restrict)

        modify :credential, :text, null: true, from: {:text, null: false}
      end

      create index(table, [:host_service_id])

      create constraint(table, "#{table}_credential_or_host_service",
               check:
                 "host_service_id IS NOT NULL OR (credential IS NOT NULL AND credential <> '')"
             )
    end
  end
end
