defmodule Backplane.Repo.Migrations.ExpandOauthTokenValues do
  use Ecto.Migration

  def change do
    alter table(:oauth_tokens) do
      modify :value, :text, from: :string
      modify :refresh_token, :text, from: :string
      modify :previous_token, :text, from: :string
      modify :previous_code, :text, from: :string
    end
  end
end
