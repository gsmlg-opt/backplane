defmodule Backplane.Diagnostics.Retention do
  @moduledoc "Expires diagnostic body data while preserving receipt and aggregate identities."

  import Ecto.Query

  alias Backplane.Diagnostics.Analyses.Job
  alias Backplane.Diagnostics.Evidence.Bundle
  alias Backplane.Diagnostics.Events.Event
  alias Backplane.Diagnostics.Outbox.Entry
  alias Backplane.Diagnostics.RepairTasks.Task, as: RepairTask
  alias Backplane.{Repo, Settings}

  @failures ~w(exception handled_error worker_exit process_exit service_restart log_error crash_artifact contract_check)
  @batch_size 500

  def policy(opts \\ []) do
    %{
      success_days: Keyword.get_lazy(opts, :success_days, fn -> days("success_days", 7, 1) end),
      exception_days:
        Keyword.get_lazy(opts, :exception_days, fn -> days("exception_days", 30, 1) end),
      summary_days:
        Keyword.get_lazy(opts, :summary_days, fn -> days("summary_days", 180, 180) end)
    }
  end

  @doc false
  def event_expires_at(%Event{} = event, policy) do
    days = if success?(event), do: policy.success_days, else: policy.exception_days
    DateTime.add(event.received_at, days, :day)
  end

  @doc "Expires one bounded batch from each store. Already-expired bodies are ignored."
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    policy = policy(opts)

    Repo.transact(
      fn ->
        {:ok,
         %{
           events: expire_events(now, policy),
           evidence: expire_evidence(now, policy),
           analyses:
             expire(
               Job,
               :finished_at,
               :result,
               DateTime.add(now, -policy.summary_days, :day),
               now
             ),
           repair_tasks:
             expire(
               RepairTask,
               :inserted_at,
               :body,
               DateTime.add(now, -policy.summary_days, :day),
               now
             )
         }}
      end,
      log: false
    )
  end

  defp expire_evidence(now, policy) do
    success_cutoff = DateTime.add(now, -policy.success_days, :day)
    exception_cutoff = DateTime.add(now, -policy.exception_days, :day)

    candidates =
      from bundle in Bundle,
        where: not is_nil(bundle.payload),
        where:
          bundle.expires_at <= ^now or
            fragment(
              """
              EXISTS (
                SELECT 1
                FROM jsonb_array_elements(? -> 'references') AS reference(item)
                JOIN diagnostics_events AS event ON event.id = CASE
                  WHEN reference.item ->> 'kind' = 'event'
                    AND reference.item ->> 'id' ~ '^event:[1-9][0-9]{0,18}$'
                  THEN CASE
                    WHEN substring(reference.item ->> 'id' FROM 7)::numeric <= 9223372036854775807
                    THEN substring(reference.item ->> 'id' FROM 7)::bigint
                  END
                END
                WHERE COALESCE(event.body #>> '{quality,evidence_expired}', '') = 'true'
                  OR event.received_at <= CASE
                    WHEN COALESCE(event.body #>> '{result,outcome}', '') = 'success'
                      AND event.event_type <> ALL(?) THEN ?
                    ELSE ?
                  END
              )
              """,
              bundle.payload,
              type(^@failures, {:array, :string}),
              type(^success_cutoff, :utc_datetime_usec),
              type(^exception_cutoff, :utc_datetime_usec)
            ),
        order_by: [asc: bundle.expires_at, asc: bundle.id],
        limit: @batch_size,
        select: bundle.id

    {count, _} =
      Bundle
      |> where([bundle], bundle.id in subquery(candidates))
      |> Repo.update_all([set: [payload: nil, expired_at: now]], log: false)

    count
  end

  defp expire_events(now, policy) do
    success_cutoff = DateTime.add(now, -policy.success_days, :day)
    exception_cutoff = DateTime.add(now, -policy.exception_days, :day)

    candidates =
      from event in Event,
        left_join: queue in Entry,
        on: queue.event_key == event.id,
        where: is_nil(queue.event_key),
        where: fragment("COALESCE(? #>> '{quality,evidence_expired}', '') <> 'true'", event.body),
        where:
          (event.event_type not in @failures and
             fragment("COALESCE(? #>> '{result,outcome}', '') = 'success'", event.body) and
             event.received_at <= ^success_cutoff) or
            ((event.event_type in @failures or
                fragment("COALESCE(? #>> '{result,outcome}', '') <> 'success'", event.body)) and
               event.received_at <= ^exception_cutoff),
        order_by: [asc: event.received_at, asc: event.id],
        limit: @batch_size,
        select: event.id

    {count, _} =
      Event
      |> where([event], event.id in subquery(candidates))
      |> update([event],
        set: [
          body:
            fragment(
              "jsonb_set(? - 'evidence', '{quality}', COALESCE(? -> 'quality', '{}'::jsonb) || '{\"evidence_expired\":true}'::jsonb, true)",
              event.body,
              event.body
            )
        ]
      )
      |> Repo.update_all([], log: false)

    count
  end

  defp expire(schema, age_field, body_field, cutoff, now) do
    candidates =
      from row in schema,
        where: field(row, ^age_field) <= ^cutoff and not is_nil(field(row, ^body_field)),
        order_by: [asc: field(row, ^age_field), asc: row.id],
        limit: @batch_size,
        select: row.id

    {count, _} =
      schema
      |> where([row], row.id in subquery(candidates))
      |> Repo.update_all([set: [{body_field, nil}, {:expired_at, now}]], log: false)

    count
  end

  defp days(key, default, minimum) do
    case Settings.get("diagnostics.retention." <> key) do
      value when is_integer(value) and value >= minimum and value <= 3_660 -> value
      _ -> default
    end
  end

  defp success?(event) do
    event.event_type not in @failures and get_in(event.body, ["result", "outcome"]) == "success"
  end

  defmodule Worker do
    @moduledoc false

    use GenServer
    require Logger

    alias Backplane.Diagnostics.Retention

    @default_interval_ms 300_000

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
      send(self(), :prune)
      {:ok, {opts, interval}}
    end

    @impl true
    def handle_info(:prune, {opts, interval} = state) do
      try do
        case Retention.prune(opts) do
          {:ok, _count} -> :ok
          {:error, _reason} -> warn()
        end
      rescue
        _error in [DBConnection.ConnectionError, Postgrex.Error] -> warn()
      end

      Process.send_after(self(), :prune, interval)
      {:noreply, state}
    end

    defp warn do
      Logger.warning("diagnostics retention unavailable", diagnostics_origin: true)
    end
  end
end
