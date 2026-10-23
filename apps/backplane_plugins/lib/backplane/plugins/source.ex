defmodule Backplane.Plugins.Source do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "plugin_sources" do
    field :name, :string
    field :url, :string
    field :ref, :string, default: "HEAD"
    field :path, :string, default: ""
    field :kind, :string, default: "plugin"
    field :credential_name, :string
    field :auto_publish, :boolean, default: false
    field :enabled, :boolean, default: true
    field :interval_seconds, :integer, default: 300
    field :last_attempt_at, :utc_datetime_usec
    field :last_success_at, :utc_datetime_usec
    field :source_commit, :string
    field :status, :string, default: "pending"
    field :diagnostics, {:array, :map}, default: []
    timestamps()
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      ~w(name url ref path kind credential_name auto_publish enabled interval_seconds last_attempt_at last_success_at source_commit status diagnostics)a
    )
    |> validate_required(~w(name url ref kind interval_seconds)a)
    |> validate_inclusion(:kind, ["plugin", "marketplace"])
    |> validate_number(:interval_seconds, greater_than_or_equal_to: 60)
  end
end
