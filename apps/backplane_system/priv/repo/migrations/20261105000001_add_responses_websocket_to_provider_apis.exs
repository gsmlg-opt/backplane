defmodule Backplane.Repo.Migrations.AddResponsesWebsocketToProviderApis do
  use Ecto.Migration

  def change do
    alter table(:llm_provider_apis) do
      add :responses_websocket, :boolean, null: false, default: false
    end
  end
end
