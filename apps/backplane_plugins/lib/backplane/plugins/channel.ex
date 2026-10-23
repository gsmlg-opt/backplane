defmodule Backplane.Plugins.Channel do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "plugin_channels" do
    field :plugin_id, Ecto.UUID
    field :release_id, Ecto.UUID
    field :name, :string
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, ~w(plugin_id release_id name)a)
    |> validate_required(~w(plugin_id release_id name)a)
    |> unique_constraint([:plugin_id, :name])
    |> foreign_key_constraint(:release_id)
  end
end
