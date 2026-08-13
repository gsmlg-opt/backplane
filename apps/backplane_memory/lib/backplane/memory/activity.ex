defmodule Backplane.Memory.Activity do
  @moduledoc "Bounded, exact-partition activity heatmaps, trends, breakdowns, and summaries."

  import Ecto.Query

  alias Backplane.Memory.Config
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ActivityContribution, ActivityDaily}

  @partition_keys ~w(host_id client_id scope namespace)a
  @counter_fields ~w(event_count memory_count lesson_count crystal_count recall_count action_count error_count)a
  @breakdown_dimensions ~w(event_type project agent_id host_id)a

  @spec heatmap(map() | keyword(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def heatmap(partition, opts \\ []) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, options} <- options(opts) do
      range = options.range

      totals =
        ActivityDaily
        |> exact_daily_partition(partition)
        |> daily_filters(options)
        |> where([row], row.date >= ^range.first and row.date <= ^range.last)
        |> group_by([row], row.date)
        |> select([row], {row.date, sum(row.event_count), sum(row.error_count)})
        |> repo().all()
        |> Map.new(fn {date, events, errors} ->
          {date, %{event_count: integer(events), error_count: integer(errors)}}
        end)

      {:ok,
       Enum.map(range, fn date ->
         Map.merge(%{date: date}, Map.get(totals, date, %{event_count: 0, error_count: 0}))
       end)}
    end
  end

  @spec trends(map() | keyword(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def trends(partition, opts \\ []) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, options} <- options(opts) do
      range = options.range

      sessions = daily_sessions(partition, options, :date)

      rows =
        ActivityDaily
        |> projected_daily(partition, options)
        |> group_by([row], row.date)
        |> order_by([row], asc: row.date)
        |> select([row], %{
          date: row.date,
          event_count: sum(row.event_count),
          memory_count: sum(row.memory_count),
          lesson_count: sum(row.lesson_count),
          crystal_count: sum(row.crystal_count),
          recall_count: sum(row.recall_count),
          action_count: sum(row.action_count),
          error_count: sum(row.error_count)
        })
        |> repo().all()
        |> Map.new(fn row ->
          row =
            row |> Map.put(:session_count, Map.get(sessions, row.date, 0)) |> normalize_counters()

          {row.date, row}
        end)

      {:ok,
       Enum.map(range, fn date ->
         Map.get(rows, date, zero_counters(date))
       end)}
    end
  end

  @spec breakdown(map() | keyword(), atom(), keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def breakdown(partition, dimension, opts \\ [])

  def breakdown(partition, dimension, opts) when dimension in @breakdown_dimensions do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, options} <- options(opts) do
      rows =
        ActivityDaily
        |> projected_daily(partition, options)
        |> where([row], field(row, ^dimension) != "")
        |> group_by([row], field(row, ^dimension))
        |> order_by([row], desc: sum(row.event_count), asc: field(row, ^dimension))
        |> limit(^options.limit)
        |> select([row], %{
          key: field(row, ^dimension),
          event_count: sum(row.event_count),
          error_count: sum(row.error_count)
        })
        |> repo().all()

      sessions = grouped_sessions(partition, options, dimension, Enum.map(rows, & &1.key))

      rows =
        Enum.map(rows, fn row ->
          row |> Map.put(:session_count, Map.get(sessions, row.key, 0)) |> normalize_counters()
        end)

      {:ok, rows}
    end
  end

  def breakdown(_partition, _dimension, _opts), do: {:error, :invalid_options}

  @doc "Returns bounded privacy-safe canonical event summaries for one exact partition."
  @spec recent_events(map() | keyword(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def recent_events(partition, opts \\ []) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, options} <- options(opts) do
      from = DateTime.new!(options.range.first, ~T[00:00:00], "Etc/UTC")
      until = DateTime.new!(Date.add(options.range.last, 1), ~T[00:00:00], "Etc/UTC")

      rows =
        Event
        |> where(
          [event],
          event.host_id == ^partition.host_id and event.client_id == ^partition.client_id and
            event.scope == ^partition.scope and event.namespace == ^partition.namespace and
            not is_nil(event.schema_version) and event.occurred_at >= ^from and
            event.occurred_at < ^until
        )
        |> daily_filters(options)
        |> order_by([event], desc: event.occurred_at, desc: event.id)
        |> limit(^options.limit)
        |> select([event], %{
          id: event.id,
          event_type: event.event_type,
          project: event.project,
          agent_id: event.agent_id,
          occurred_at: event.occurred_at
        })
        |> repo().all()

      {:ok, rows}
    end
  end

  @spec summary(map() | keyword(), keyword()) :: {:ok, map()} | {:error, atom()}
  def summary(partition, opts \\ []) do
    metadata = if is_map(partition), do: partition, else: Map.new(partition)

    Backplane.Memory.PipelineTelemetry.span("activity.summary", metadata, fn ->
      do_summary(partition, opts)
    end)
  end

  defp do_summary(partition, opts) do
    with {:ok, partition} <- exact_partition(partition),
         {:ok, options} <- options(opts) do
      counters =
        ActivityDaily
        |> projected_daily(partition, options)
        |> select([row], %{
          event_count: sum(row.event_count),
          memory_count: sum(row.memory_count),
          lesson_count: sum(row.lesson_count),
          crystal_count: sum(row.crystal_count),
          recall_count: sum(row.recall_count),
          action_count: sum(row.action_count),
          error_count: sum(row.error_count)
        })
        |> repo().one!()
        |> Map.put(:session_count, distinct_sessions(partition, options))
        |> normalize_counters()

      {:ok, Map.merge(counters, %{date_from: options.range.first, date_to: options.range.last})}
    end
  end

  defp exact_partition(partition) when is_list(partition),
    do: partition |> Map.new() |> exact_partition()

  defp exact_partition(partition) when is_map(partition) do
    values =
      Map.new(@partition_keys, fn key ->
        {key, Map.get(partition, key) || Map.get(partition, Atom.to_string(key))}
      end)

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and String.trim(value) != "" end),
      do: {:ok, values},
      else: {:error, :unauthorized}
  end

  defp exact_partition(_partition), do: {:error, :unauthorized}

  defp options(opts) when is_list(opts) do
    allowed = [:date_from, :date_to, :project, :agent_id, :event_type, :limit]
    today = Date.utc_today()
    retention = Config.activity_retention_days()

    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [],
         %Date{} = from <- Keyword.get(opts, :date_from, Date.add(today, 1 - retention)),
         %Date{} = to <- Keyword.get(opts, :date_to, today),
         days when days >= 0 and days < retention <- Date.diff(to, from),
         true <- valid_filter?(Keyword.get(opts, :project)),
         true <- valid_filter?(Keyword.get(opts, :agent_id)),
         true <- valid_filter?(Keyword.get(opts, :event_type)),
         limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 20) do
      {:ok,
       %{
         range: Date.range(from, to),
         project: Keyword.get(opts, :project),
         agent_id: Keyword.get(opts, :agent_id),
         event_type: Keyword.get(opts, :event_type),
         limit: limit
       }}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp options(_opts), do: {:error, :invalid_options}

  defp valid_filter?(nil), do: true
  defp valid_filter?(value) when is_binary(value), do: value != "" and byte_size(value) <= 512
  defp valid_filter?(_value), do: false

  defp exact_daily_partition(query, partition) do
    where(
      query,
      [row],
      row.host_id == ^partition.host_id and row.client_id == ^partition.client_id and
        row.scope == ^partition.scope and row.namespace == ^partition.namespace
    )
  end

  defp exact_contribution_partition(query, partition) do
    where(
      query,
      [row],
      row.host_id == ^partition.host_id and row.client_id == ^partition.client_id and
        row.scope == ^partition.scope and row.namespace == ^partition.namespace
    )
  end

  defp projected_daily(query, partition, options) do
    query
    |> exact_daily_partition(partition)
    |> where([row], row.date >= ^options.range.first and row.date <= ^options.range.last)
    |> daily_filters(options)
  end

  defp projected_contributions(query, partition, options) do
    query
    |> exact_contribution_partition(partition)
    |> where([row], row.date >= ^options.range.first and row.date <= ^options.range.last)
    |> daily_filters(options)
  end

  defp daily_filters(query, options) do
    query
    |> maybe_filter(:project, options.project)
    |> maybe_filter(:agent_id, options.agent_id)
    |> maybe_filter(:event_type, options.event_type)
  end

  defp daily_sessions(partition, options, dimension) do
    ActivityContribution
    |> projected_contributions(partition, options)
    |> group_by([row], field(row, ^dimension))
    |> select([row], {field(row, ^dimension), count(row.subject_id, :distinct)})
    |> repo().all()
    |> Map.new()
  end

  defp grouped_sessions(_partition, _options, _dimension, []), do: %{}

  defp grouped_sessions(partition, options, dimension, keys) do
    ActivityContribution
    |> projected_contributions(partition, options)
    |> where([row], field(row, ^dimension) in ^keys)
    |> group_by([row], field(row, ^dimension))
    |> select([row], {field(row, ^dimension), count(row.subject_id, :distinct)})
    |> repo().all()
    |> Map.new()
  end

  defp distinct_sessions(partition, options) do
    ActivityContribution
    |> projected_contributions(partition, options)
    |> select([row], count(row.subject_id, :distinct))
    |> repo().one()
  end

  defp maybe_filter(query, _field_name, nil), do: query

  defp maybe_filter(query, field_name, value) do
    where(query, [row], field(row, ^field_name) == ^value)
  end

  defp normalize_counters(row) do
    Map.new(row, fn
      {:date, date} -> {:date, date}
      {:key, key} -> {:key, key}
      {key, value} -> {key, integer(value)}
    end)
  end

  defp zero_counters(date) do
    @counter_fields
    |> Enum.reduce(%{date: date, session_count: 0}, &Map.put(&2, &1, 0))
  end

  defp integer(nil), do: 0
  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(value) when is_integer(value), do: value

  defp repo, do: Application.fetch_env!(:backplane_memory, :repo)
end
