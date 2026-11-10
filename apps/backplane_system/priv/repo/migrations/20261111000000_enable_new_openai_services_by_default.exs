defmodule Backplane.Repo.Migrations.EnableNewOpenaiServicesByDefault do
  use Ecto.Migration

  def change do
    alter table(:llm_openai_services) do
      modify :enabled, :boolean,
        default: true,
        null: false,
        from: {:boolean, default: false, null: false}
    end
  end
end
