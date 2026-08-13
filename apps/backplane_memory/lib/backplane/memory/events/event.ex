defmodule Backplane.Memory.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.Memory.Events.Types

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bpm_events" do
    field :stream_id, :string
    field :sequence, :integer
    field :project, :string
    field :namespace, :string, default: "private"
    field :agent_id, :string
    field :host_id, :string
    field :client_id, :string
    field :session_id, :string
    field :run_id, :string
    field :event_type, :string
    field :actor_type, :string
    field :role, :string
    field :status, :string
    field :tool_name, :string
    field :content, :string
    field :correlation_id, :string
    field :idempotency_key, :string
    field :importance, :integer, default: 0
    field :payload, :map, default: %{}
    field :schema_version, :integer
    field :integration, :string
    field :scope, :string
    field :parent_session_id, :string
    field :source_sequence, :integer
    field :captured_at, :utc_datetime_usec
    field :payload_hash, :string
    field :privacy, :map, default: %{}
    field :trace, :map, default: %{}
    field :raw_envelope, :map, default: %{}
    field :ingest_auth_token_id, :string
    field :causation_id, :binary_id
    field :occurred_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, __schema__(:fields) -- [:inserted_at])
    |> validate_required([
      :id,
      :stream_id,
      :sequence,
      :namespace,
      :event_type,
      :importance,
      :payload,
      :occurred_at
    ])
    |> validate_inclusion(:event_type, Types.accepted_types())
    |> unique_constraint(:id, name: :bpm_events_pkey)
    |> unique_constraint(:source_sequence, name: :bpm_events_capture_source_identity_uniq)
    |> foreign_key_constraint(:stream_id, name: :bpm_events_stream_id_fkey)
    |> unique_constraint(:sequence, name: :bpm_events_stream_sequence_uniq)
    |> unique_constraint(:idempotency_key, name: :bpm_events_idempotency_key_uniq)
  end
end
