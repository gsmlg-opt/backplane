defmodule Backplane.Settings.Setting do
  @moduledoc "Ecto schema for the system_settings table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts false

  schema "system_settings" do
    field :value, :map
    field :value_type, :string, default: "string"
    field :description, :string
    field :updated_at, :utc_datetime_usec
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :value_type, :description])
    |> validate_required([:key, :value, :value_type])
    |> validate_inclusion(:value_type, ~w(string integer boolean json))
  end
end
