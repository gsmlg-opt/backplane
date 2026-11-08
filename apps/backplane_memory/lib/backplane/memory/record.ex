defmodule Backplane.Memory.Record do
  @moduledoc """
  A single entry in the global, provenance-tagged memory store.

  Provenance fields (`writer`, `host_id`, `agent_id`, ...) describe where a
  record came from; they are never used to authorize access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(fact procedure worklog note)
  @statuses ~w(active superseded forgotten)
  @writers ~w(agent memory_agent user host_collector)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "memory_records" do
    field(:kind, :string, default: "note")
    field(:title, :string)
    field(:content, :string)
    field(:subjects, {:array, :map}, default: [])
    field(:subject_keys, {:array, :string}, default: [])
    field(:property, :string)
    field(:tags, {:array, :string}, default: [])
    field(:confidence, :float)
    field(:status, :string, default: "active")
    field(:superseded_by, :binary_id)
    field(:forgotten_reason, :string)
    field(:forgotten_at, :utc_datetime_usec)
    field(:writer, :string)
    field(:host_id, :string)
    field(:agent_id, :string)
    field(:integration, :string)
    field(:session_id, :string)
    field(:client_id, :string)
    field(:source_event_ids, {:array, :binary_id}, default: [])
    field(:request_key, :string)
    field(:observed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(kind title content subjects subject_keys property tags confidence status
               superseded_by forgotten_reason forgotten_at writer host_id agent_id integration
               session_id client_id source_event_ids request_key observed_at)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @castable)
    |> validate_required([:kind, :content, :writer, :observed_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:writer, @writers)
    |> unique_constraint(:request_key)
  end
end
