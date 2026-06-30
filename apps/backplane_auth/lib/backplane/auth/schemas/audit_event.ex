defmodule Backplane.Auth.Schemas.AuditEvent do
  @moduledoc "Append-only security audit event for Backplane Auth."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "auth_audit_events" do
    field :event_type, :string
    field :actor_type, :string
    field :actor_id, :string
    field :target_type, :string
    field :target_id, :string
    field :severity, :string, default: "info"
    field :ip, :string
    field :user_agent, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_type,
      :actor_type,
      :actor_id,
      :target_type,
      :target_id,
      :severity,
      :ip,
      :user_agent,
      :metadata
    ])
    |> validate_required([:event_type, :severity])
  end
end
