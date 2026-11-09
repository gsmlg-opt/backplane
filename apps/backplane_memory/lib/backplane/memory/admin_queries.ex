defmodule Backplane.Memory.AdminQueries do
  @moduledoc "Bounded read-only queries for the admin Memory pages."

  import Ecto.Query

  alias Backplane.Memory.Distillations
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.ProjectedSession
  alias Backplane.Memory.Record

  @default_limit 50
  @max_limit 200

  @doc "Record counts keyed by `{kind, status}`."
  @spec record_counts() :: %{{String.t(), String.t()} => non_neg_integer()}
  def record_counts do
    Record
    |> group_by([r], [r.kind, r.status])
    |> select([r], {{r.kind, r.status}, count(r.id)})
    |> repo().all()
    |> Map.new()
  end

  @spec event_count_since(DateTime.t()) :: non_neg_integer()
  def event_count_since(%DateTime{} = since) do
    Event |> where([e], e.inserted_at >= ^since) |> repo().aggregate(:count)
  end

  @spec open_session_count() :: non_neg_integer()
  def open_session_count do
    ProjectedSession |> where([s], s.status == "active") |> repo().aggregate(:count)
  end

  @spec recent_events(pos_integer()) :: [struct()]
  def recent_events(limit \\ @default_limit) do
    Event
    |> order_by([e], desc: e.occurred_at, desc: e.inserted_at)
    |> limit(^clamp(limit))
    |> repo().all()
  end

  @doc "Recent sessions with a captured event count."
  @spec recent_sessions(pos_integer()) :: [
          %{session: struct(), event_count: integer(), distillation: struct() | nil}
        ]
  def recent_sessions(limit \\ @default_limit) do
    sessions =
      ProjectedSession
      |> order_by([s], desc: s.last_event_at)
      |> limit(^clamp(limit))
      |> repo().all()

    session_ids = Enum.map(sessions, & &1.session_id)

    counts =
      Event
      |> where([e], e.session_id in ^session_ids)
      |> group_by([e], [e.host_id, e.session_id])
      |> select([e], {{e.host_id, e.session_id}, count(e.id)})
      |> repo().all()
      |> Map.new()

    distillations = Distillations.for_subjects(Enum.map(sessions, & &1.subject_id))

    Enum.map(sessions, fn s ->
      %{
        session: s,
        event_count: Map.get(counts, {s.host_id, s.session_id}, 0),
        distillation: Map.get(distillations, s.subject_id)
      }
    end)
  end

  defp clamp(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp(_), do: @default_limit

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
