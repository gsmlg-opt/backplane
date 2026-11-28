defmodule Backplane.Diagnostics.Occurrences do
  @moduledoc "Joins independently received evidence for a confirmed diagnostic occurrence."

  import Ecto.Query

  alias Backplane.Diagnostics.Events.Event
  alias Backplane.DiagnosticsClient.Canonical
  alias Backplane.Repo

  defmodule Occurrence do
    @moduledoc false
    use Ecto.Schema

    schema "diagnostics_occurrences" do
      field :source_id, :string
      field :identity, :string
      field :run_key, :id
      field :rule, :string
      field :category, :string
      field :certainty, :string
      field :first_seen_at, :utc_datetime_usec
      field :last_seen_at, :utc_datetime_usec
    end
  end

  defmodule Evidence do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "diagnostics_occurrence_events" do
      field :occurrence_id, :id, primary_key: true
      field :event_key, :id, primary_key: true
    end
  end

  @doc false
  def observe(%Event{} = event, run, finding) do
    identity = identity(event)

    Repo.insert_all(
      Occurrence,
      [
        %{
          source_id: event.source_id,
          identity: identity,
          run_key: run && run.id,
          rule: finding.rule,
          category: finding.category,
          certainty: finding.status,
          first_seen_at: event.occurred_at,
          last_seen_at: event.occurred_at
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:source_id, :identity],
      log: false
    )

    occurrence = lock_occurrence(event.source_id, identity)
    attach(occurrence, event, run)
  end

  @doc false
  def corroborate(%Event{} = event, run) do
    if explicit_identity(event.body) do
      case lock_occurrence(event.source_id, identity(event)) do
        nil -> nil
        occurrence -> attach(occurrence, event, run)
      end
    end
  end

  defp lock_occurrence(source_id, identity) do
    Occurrence
    |> where([row], row.source_id == ^source_id and row.identity == ^identity)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp attach(occurrence, event, run) do
    {added, _} =
      Repo.insert_all(Evidence, [%{occurrence_id: occurrence.id, event_key: event.id}],
        on_conflict: :nothing,
        conflict_target: [:occurrence_id, :event_key],
        log: false
      )

    if added == 1 do
      earlier = earlier(event.occurred_at, occurrence.first_seen_at)
      later = later(event.occurred_at, occurrence.last_seen_at)

      occurrence
      |> Ecto.Changeset.change(
        first_seen_at: earlier,
        last_seen_at: later,
        run_key: occurrence.run_key || (run && run.id)
      )
      |> Repo.update!(log: false)
    else
      occurrence
    end
  end

  defp earlier(left, right), do: if(DateTime.before?(left, right), do: left, else: right)
  defp later(left, right), do: if(DateTime.after?(left, right), do: left, else: right)

  defp identity(event) do
    parts = explicit_identity(event.body) || ["event", event.event_id]
    {:ok, bytes} = Canonical.encode(parts)
    Canonical.digest(bytes)
  end

  defp explicit_identity(body) do
    subject = body["subject"] || %{}
    correlation = body["correlation"] || %{}

    cond do
      is_binary(correlation["occurrence_hint"]) ->
        ["hint", correlation["occurrence_hint"]]

      is_binary(subject["run_id"]) and is_binary(subject["attempt_id"]) and
          is_binary(subject["tool_invocation_id"]) ->
        ["tool", subject["run_id"], subject["attempt_id"], subject["tool_invocation_id"]]

      is_binary(subject["run_id"]) and is_binary(subject["attempt_id"]) and
          is_binary(correlation["request_id"]) ->
        ["request", subject["run_id"], subject["attempt_id"], correlation["request_id"]]

      true ->
        nil
    end
  end
end
