defmodule Backplane.Monitor.Plan do
  @moduledoc """
  Ecto schema for subscription plan monitoring definitions.

  Each plan tracks a specific provider subscription (z.ai, MiniMax, etc.)
  and references a credential by name for API key access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @providers ~w(zai minimax openai_codex claude_code google_ai)

  schema "monitor_plans" do
    field :name, :string
    field :provider, :string
    field :credential_name, :string
    field :config, :map, default: %{}
    field :active, :boolean, default: true

    timestamps()
  end

  @required_fields ~w(name provider credential_name)a
  @optional_fields ~w(config active)a

  @doc "Returns the list of valid provider identifiers."
  @spec providers() :: [String.t()]
  def providers, do: @providers

  @doc "Changeset for creating or updating a plan."
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint(:name)
  end

  @doc "Returns a human-readable label for the provider."
  @spec provider_label(String.t()) :: String.t()
  def provider_label("zai"), do: "z.ai"
  def provider_label("minimax"), do: "MiniMax"
  def provider_label("openai_codex"), do: "OpenAI Codex"
  def provider_label("claude_code"), do: "Claude Code"
  def provider_label("google_ai"), do: "Google AI"
  def provider_label(other), do: other

  @doc "Returns true if the provider's usage fetcher is implemented."
  @spec provider_supported?(String.t()) :: boolean()
  def provider_supported?("zai"), do: true
  def provider_supported?("minimax"), do: true
  def provider_supported?("openai_codex"), do: true
  def provider_supported?("claude_code"), do: true
  def provider_supported?(_), do: false
end
