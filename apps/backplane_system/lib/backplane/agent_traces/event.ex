defmodule Backplane.AgentTraces.Event do
  @moduledoc "Ecto schema for trace events synced from host agents."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "agent_trace_events" do
    field(:host_id, :binary_id)
    field(:agent_seq, :integer)
    field(:trace_id, :string)
    field(:span_id, :string)
    field(:parent_id, :string)
    field(:event, :string)
    field(:measurements, :map, default: %{})
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end

  @required ~w(host_id agent_seq trace_id span_id event measurements metadata occurred_at)a
  @optional ~w(parent_id)a

  @doc false
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:agent_seq, greater_than_or_equal_to: 0)
    |> validate_format(:trace_id, ~r/\A[0-9a-fA-F]{32}\z/)
    |> validate_format(:span_id, ~r/\A[0-9a-fA-F]{16}\z/)
    |> validate_format(:parent_id, ~r/\A[0-9a-fA-F]{16}\z/)
    |> validate_format(:event, ~r/\A[[:alnum:]_]+(\.[[:alnum:]_]+)+\z/)
    |> unique_constraint(:agent_seq,
      name: :agent_trace_events_host_id_agent_seq_index
    )
  end
end
