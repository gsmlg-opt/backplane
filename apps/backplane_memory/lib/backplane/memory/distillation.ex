defmodule Backplane.Memory.Distillation do
  @moduledoc "Per-session background distillation state (one row per projected session)."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:subject_id, :string, autogenerate: false}

  schema "memory_distillations" do
    field(:host_id, :string)
    field(:session_id, :string)
    field(:agent_id, :string)
    field(:integration, :string)
    field(:status, :string, default: "pending")
    field(:mode, :string, default: "distill")
    field(:attempts, :integer, default: 0)
    field(:due_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:last_error, :string)
    field(:records_written, :integer, default: 0)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:distilled_through_sequence, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end
end
