defmodule Backplane.Plugins.Plugin do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "plugins" do
    field :identity, :string
    field :publisher, :string
    field :name, :string
    field :source_id, Ecto.UUID
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, ~w(identity publisher name source_id)a)
    |> validate_required(~w(identity publisher name)a)
    |> unique_constraint(:identity)
    |> foreign_key_constraint(:source_id)
  end
end
