defmodule Backplane.Admin.Audit.Event do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "admin_audit_events" do
    field :actor, :string, default: "trusted_operator"
    field :source, :string, default: "admin_ui"
    field :action, :string
    field :target_type, :string
    field :target_id, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
