defmodule Backplane.Monitor.ApiAccount do
  @moduledoc "An API account monitored through references to vaulted API keys."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @providers ~w(openrouter deepseek exa tavily firecrawl)

  schema "monitor_api_accounts" do
    field :name, :string
    field :provider, :string
    field :credential_name, :string
    field :management_credential_name, :string
    field :active, :boolean, default: true

    timestamps()
  end

  @type t :: %__MODULE__{}

  def providers, do: @providers
  def provider_label("openrouter"), do: "OpenRouter"
  def provider_label("deepseek"), do: "DeepSeek"
  def provider_label("exa"), do: "Exa"
  def provider_label("tavily"), do: "Tavily"
  def provider_label("firecrawl"), do: "Firecrawl"

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :name,
      :provider,
      :credential_name,
      :management_credential_name,
      :active
    ])
    |> validate_required([:name, :provider, :credential_name])
    |> validate_inclusion(:provider, @providers)
    |> check_constraint(:provider, name: :monitor_api_accounts_provider)
    |> validate_length(:name, max: 255)
    |> validate_management_credential()
    |> unique_constraint(:name)
  end

  defp validate_management_credential(changeset) do
    if get_field(changeset, :provider) != "openrouter" and
         get_field(changeset, :management_credential_name) do
      add_error(changeset, :management_credential_name, "is only supported for OpenRouter")
    else
      changeset
    end
  end
end
