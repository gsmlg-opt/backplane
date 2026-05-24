defmodule Backplane.Settings.Credential do
  @moduledoc "Ecto schema for the credentials table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @derive {Inspect, except: [:encrypted_value]}
  schema "credentials" do
    field :name, :string
    field :kind, :string
    field :encrypted_value, :binary
    field :metadata, :map, default: %{}

    timestamps()
  end

  @valid_kinds ~w(llm upstream service admin custom)

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:name, :kind, :encrypted_value, :metadata])
    |> validate_required([:name, :kind, :encrypted_value])
    |> validate_inclusion(:kind, @valid_kinds)
    |> unique_constraint(:name)
  end
end
