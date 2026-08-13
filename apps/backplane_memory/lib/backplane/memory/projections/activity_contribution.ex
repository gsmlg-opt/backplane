defmodule Backplane.Memory.Projections.ActivityContribution do
  @moduledoc "One captured-session revision's contribution to durable daily activity."

  use Ecto.Schema

  @primary_key false
  schema "memory_activity_subject_contributions" do
    field :subject_id, :string, primary_key: true
    field :date, :date, primary_key: true
    field :project, :string, primary_key: true
    field :agent_id, :string, primary_key: true
    field :host_id, :string, primary_key: true
    field :client_id, :string, primary_key: true
    field :scope, :string, primary_key: true
    field :namespace, :string, primary_key: true
    field :event_type, :string, primary_key: true
    field :event_count, :integer
    field :session_count, :integer
    field :memory_count, :integer
    field :lesson_count, :integer
    field :crystal_count, :integer
    field :recall_count, :integer
    field :action_count, :integer
    field :error_count, :integer
    field :processing_version, :string
    field :input_revision, :string
    timestamps(type: :utc_datetime_usec)
  end
end
