defmodule Backplane.Memory.Projections.ActivityDaily do
  @moduledoc "Durable daily activity aggregate isolated by memory partition."

  use Ecto.Schema

  @primary_key false
  schema "memory_activity_daily" do
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
    timestamps(type: :utc_datetime_usec)
  end
end
