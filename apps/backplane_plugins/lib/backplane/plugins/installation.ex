defmodule Backplane.Plugins.Installation do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "plugin_installations" do
    field :target, :string
    field :plugin_id, Ecto.UUID
    field :desired_release_id, Ecto.UUID
    field :actual_release_id, Ecto.UUID
    field :enabled, :boolean, default: true
    field :actual_enabled, :boolean
    field :status, :string, default: "pending"
    field :components, :map, default: %{}
    field :diagnostics, {:array, :map}, default: []
    field :reported_at, :utc_datetime_usec
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      ~w(target plugin_id desired_release_id actual_release_id enabled actual_enabled status components diagnostics reported_at)a
    )
    |> validate_required(~w(target plugin_id desired_release_id status)a)
    |> validate_inclusion(:status, ~w(pending installed enabled failed partial disabled))
    |> unique_constraint([:target, :plugin_id])
    |> foreign_key_constraint(:desired_release_id)
    |> foreign_key_constraint(:actual_release_id)
  end
end
