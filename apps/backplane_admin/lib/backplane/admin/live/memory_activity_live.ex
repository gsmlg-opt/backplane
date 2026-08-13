defmodule Backplane.Admin.MemoryActivityLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.{Activity, ActivityNotifier, Config}
  alias Backplane.Memory.Operations.Activity, as: OperatorActivity
  alias Backplane.Skills.AgentManage

  @distribution_limit 100
  @distribution_page_size 10
  @filter_keys ~w(project agent_id event_type)
  @periods ~w(daily monthly yearly)
  @partition_keys ~w(host_id client_id scope namespace)

  @impl true
  def mount(_params, _session, socket) do
    partitions = load_partitions()
    partition = List.first(partitions)

    if connected?(socket) do
      :ok = ActivityNotifier.subscribe()
      :ok = AgentManage.subscribe()
    end

    socket =
      assign(socket,
        current_path: "/memory/activity",
        partitions: partitions,
        partition: partition,
        selected_partition_index: if(partition, do: "0"),
        filters: %{},
        period: "daily",
        distribution_page: 1,
        heatmap: [],
        trends: [],
        distribution: [],
        project_breakdown: [],
        agent_breakdown: [],
        host_breakdown: [],
        recent_events: [],
        host_health: host_health(partition),
        summary: zero_summary(),
        query_error: nil,
        live_update: false
      )

    {:ok, if(partition, do: reload(socket), else: socket)}
  end

  @impl true
  def handle_event("select_partition", %{"selection" => %{"index" => raw_index}}, socket) do
    with {index, ""} when index >= 0 <- Integer.parse(raw_index),
         partition when not is_nil(partition) <- Enum.at(socket.assigns.partitions, index) do
      {:noreply,
       socket
       |> assign(
         partition: partition,
         selected_partition_index: Integer.to_string(index),
         filters: %{},
         distribution_page: 1,
         host_health: host_health(partition),
         live_update: false
       )
       |> reload()}
    else
      _invalid -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => raw}, socket) do
    case normalize_filters(raw) do
      {:ok, filters} ->
        {:noreply,
         socket
         |> assign(filters: filters, distribution_page: 1, live_update: false)
         |> reload()}

      {:error, reason} ->
        {:noreply, assign(socket, query_error: reason)}
    end
  end

  def handle_event("period", %{"period" => period}, socket) when period in @periods do
    {:noreply, assign(socket, period: period)}
  end

  def handle_event("distribution_page", %{"direction" => direction}, socket) do
    last_page = distribution_pages(socket.assigns.distribution)

    page =
      case direction do
        "next" -> min(socket.assigns.distribution_page + 1, last_page)
        "previous" -> max(socket.assigns.distribution_page - 1, 1)
        _invalid -> socket.assigns.distribution_page
      end

    {:noreply, assign(socket, distribution_page: page)}
  end

  @impl true
  def handle_info({:memory_activity_updated, summary}, socket) do
    if relevant_update?(summary, socket.assigns.partition, retention_range()) do
      {:noreply, socket |> assign(live_update: true) |> reload()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:agents_changed, socket) do
    {:noreply, assign(socket, host_health: host_health(socket.assigns.partition))}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:periods, @periods)
      |> assign(:visible_distribution, visible_distribution(assigns))
      |> assign(:distribution_pages, distribution_pages(assigns.distribution))
      |> assign(:period_trends, aggregate_trends(assigns.trends, assigns.period))

    ~H"""
    <div id="memory-activity">
      <.memory_page_header title="Activity" subtitle="Durable exact-partition activity projections" />

      <.dm_alert :if={is_nil(@partition)} id="activity-partition-unavailable" variant="error" title="Activity partition unavailable" compact>
        No complete durable activity partition is available.
      </.dm_alert>

      <.dm_alert :if={@query_error} id="activity-query-error" variant="error" title="Activity unavailable" compact>
        Activity projections could not be loaded with the selected filters.
      </.dm_alert>

      <.dm_alert :if={@live_update} id="activity-live-update" variant="info" title="Live update received" compact>
        The view was reloaded from PostgreSQL after projection commit.
      </.dm_alert>

      <.form
        :if={@partitions != []}
        id="activity-partition-selector"
        for={%{}}
        as={:selection}
        phx-change="select_partition"
        class="mt-4 max-w-3xl"
      >
        <.dm_select
          id="activity-partition"
          name="selection[index]"
          label="Durable activity partition"
          value={@selected_partition_index}
          options={partition_options(@partitions)}
        />
        <p class="mt-1 text-xs text-on-surface-variant">
          Partitions are enumerated from durable server-side activity data for this trusted operator UI.
        </p>
      </.form>

      <div :if={@partition}>
        <.dm_card variant="bordered" padding="sm">
          <dl class="grid gap-2 text-sm sm:grid-cols-4">
            <div><dt class="text-on-surface-variant">Host</dt><dd id="activity-exact-host" class="font-mono">{@partition.host_id}</dd></div>
            <div><dt class="text-on-surface-variant">Client</dt><dd class="font-mono">{@partition.client_id}</dd></div>
            <div><dt class="text-on-surface-variant">Scope</dt><dd>{@partition.scope}</dd></div>
            <div><dt class="text-on-surface-variant">Namespace</dt><dd>{@partition.namespace}</dd></div>
          </dl>
        </.dm_card>

        <section class="mt-4" aria-labelledby="activity-host-health-title">
          <h2 id="activity-host-health-title" class="text-lg font-semibold">
            Host capture and delivery health
          </h2>
          <.dm_card :if={is_nil(@host_health)} id="activity-host-health" variant="bordered" padding="sm" class="mt-3">
            No capture telemetry has been reported for this host.
          </.dm_card>
          <div :if={@host_health} class="mt-3 overflow-x-auto">
            <table id="activity-host-health" class="min-w-full text-sm">
              <thead class="bg-surface-container-high text-on-surface">
                <tr>
                  <th class="px-3 py-2 text-left">Connection</th>
                  <th class="px-3 py-2 text-left">Version</th>
                  <th class="px-3 py-2 text-right">Queue</th>
                  <th class="px-3 py-2 text-right">Oldest</th>
                  <th class="px-3 py-2 text-right">Captured / redacted / rejected</th>
                  <th class="px-3 py-2 text-right">Retries / dead letters</th>
                  <th class="px-3 py-2 text-right">Upload / ACK</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td class="px-3 py-2">{capture_state_label(@host_health)}</td>
                  <td class="px-3 py-2 font-mono text-xs">{agent_version(@host_health)}</td>
                  <td class="px-3 py-2 text-right">
                    {capture_value(@host_health, "spool_depth", 0)} / {format_bytes(capture_value(@host_health, "spool_bytes", 0))}
                  </td>
                  <td class="px-3 py-2 text-right">{format_age(capture_value(@host_health, "oldest_event_age_ms", 0))}</td>
                  <td class="px-3 py-2 text-right">
                    {capture_value(@host_health, "captured_count", 0)} / {capture_value(@host_health, "redacted_count", 0)} / {capture_value(@host_health, "rejected_count", 0)}
                  </td>
                  <td class="px-3 py-2 text-right">
                    {capture_value(@host_health, "retry_count", 0)} / {capture_value(@host_health, "dead_letter_count", 0)}
                  </td>
                  <td class="px-3 py-2 text-right">{format_latency(@host_health)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <.form id="activity-filters" for={%{}} as={:filters} phx-change="filter" phx-submit="filter" class="mt-4 grid gap-3 md:grid-cols-4">
          <.dm_input id="activity-host-filter" name="filters[host_id]" label="Host" value={@partition.host_id} readonly />
          <.dm_input id="activity-project-filter" name="filters[project]" label="Project" value={@filters["project"]} phx-debounce="300" />
          <.dm_input id="activity-agent-filter" name="filters[agent_id]" label="Agent" value={@filters["agent_id"]} phx-debounce="300" />
          <.dm_input id="activity-event-filter" name="filters[event_type]" label="Event type" value={@filters["event_type"]} phx-debounce="300" />
        </.form>

        <section id="activity-summary" class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <.summary_stat id="activity-summary-events" label="Events" value={@summary.event_count} />
          <.summary_stat id="activity-summary-sessions" label="Sessions" value={@summary.session_count} />
          <.summary_stat id="activity-summary-errors" label="Errors" value={@summary.error_count} />
          <.summary_stat id="activity-summary-recalls" label="Recalls" value={@summary.recall_count} />
        </section>

        <section class="mt-6" aria-labelledby="activity-heatmap-title">
          <h2 id="activity-heatmap-title" class="text-lg font-semibold">Historical heatmap</h2>
          <p class="text-sm text-on-surface-variant">Configured {Config.activity_retention_days()}-day retention window ending today; darker cells contain more projected events.</p>
          <div id="activity-heatmap" class="mt-3 grid grid-flow-col grid-rows-7 gap-1 overflow-x-auto pb-2" role="grid" aria-label="Historical activity heatmap">
            <span
              :for={day <- @heatmap}
              data-date={Date.to_iso8601(day.date)}
              data-level={heat_level(day.event_count)}
              class={heat_class(day.event_count)}
              title={"#{Date.to_iso8601(day.date)}: #{day.event_count} events, #{day.error_count} errors"}
              role="gridcell"
            ></span>
          </div>
        </section>

        <section class="mt-6" aria-labelledby="activity-trends-title">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 id="activity-trends-title" class="text-lg font-semibold">Trends</h2>
            <div class="flex gap-2" role="group" aria-label="Trend period">
              <.dm_btn :for={period <- @periods} id={"activity-period-#{period}"} type="button" size="sm" variant={if @period == period, do: "primary", else: "outline"} phx-click="period" phx-value-period={period}>
                {String.capitalize(period)}
              </.dm_btn>
            </div>
          </div>
          <div class="mt-3 overflow-x-auto">
            <.dm_table id="activity-trends" data={@period_trends} compact hover zebra>
              <:col :let={row} label="Period"><span data-period={row.period}>{row.period}</span></:col>
              <:col :let={row} label="Events">{row.event_count}</:col>
              <:col :let={row} label="Sessions">{row.session_count}</:col>
              <:col :let={row} label="Errors">{row.error_count}</:col>
              <:col :let={row} label="Memories / Lessons / Crystals">{row.memory_count} / {row.lesson_count} / {row.crystal_count}</:col>
              <:col :let={row} label="Actions">{row.action_count}</:col>
              <:col :let={row} label="Recalls">{row.recall_count}</:col>
            </.dm_table>
          </div>
        </section>

        <section class="mt-6 grid gap-4 xl:grid-cols-3" aria-label="Activity breakdowns">
          <.activity_breakdown
            id="activity-project-breakdown"
            title="Activity by project"
            key_label="Project"
            rows={@project_breakdown}
          />
          <.activity_breakdown
            id="activity-agent-breakdown"
            title="Activity by agent"
            key_label="Agent"
            rows={@agent_breakdown}
          />
          <.activity_breakdown
            id="activity-host-breakdown"
            title="Activity by host"
            key_label="Host"
            rows={@host_breakdown}
          />
        </section>

        <section class="mt-6" aria-labelledby="activity-distribution-title">
          <h2 id="activity-distribution-title" class="text-lg font-semibold">Event distribution</h2>
          <div class="mt-3 overflow-x-auto">
            <.dm_table id="activity-event-distribution" data={@visible_distribution} compact hover zebra>
              <:col :let={row} label="Event type">{row.key}</:col>
              <:col :let={row} label="Events">{row.event_count}</:col>
              <:col :let={row} label="Sessions">{row.session_count}</:col>
              <:col :let={row} label="Errors">{row.error_count}</:col>
            </.dm_table>
          </div>
          <nav :if={@distribution_pages > 1} class="mt-3 flex items-center justify-between" aria-label="Event distribution pagination">
            <.dm_btn :if={@distribution_page > 1} id="activity-distribution-previous" type="button" size="sm" variant="outline" phx-click="distribution_page" phx-value-direction="previous">Previous</.dm_btn>
            <span class="text-sm text-on-surface-variant">Page {@distribution_page} of {@distribution_pages}</span>
            <.dm_btn :if={@distribution_page < @distribution_pages} id="activity-distribution-next" type="button" size="sm" variant="outline" phx-click="distribution_page" phx-value-direction="next">Next</.dm_btn>
          </nav>
        </section>

        <section class="mt-6" aria-labelledby="activity-recent-events-title">
          <h2 id="activity-recent-events-title" class="text-lg font-semibold">Recent live events</h2>
          <p class="text-sm text-on-surface-variant">
            Privacy-safe canonical summaries from the selected exact partition.
          </p>
          <div class="mt-3 overflow-x-auto">
            <.dm_table id="activity-recent-events" data={@recent_events} compact hover zebra>
              <:col :let={event} label="Event">
                <.link href={~p"/memory/events/#{event.id}"} class="font-mono text-primary underline">
                  {event.event_type}
                </.link>
              </:col>
              <:col :let={event} label="Project">{event.project || "—"}</:col>
              <:col :let={event} label="Agent">{event.agent_id || "—"}</:col>
              <:col :let={event} label="Occurred">{format_datetime(event.occurred_at)}</:col>
            </.dm_table>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)

  defp summary_stat(assigns) do
    ~H"""
    <.dm_card id={@id} variant="bordered" padding="sm">
      <p class="text-sm text-on-surface-variant">{@label}</p>
      <p class="mt-1 text-2xl font-semibold">{@value}</p>
    </.dm_card>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:key_label, :string, required: true)
  attr(:rows, :list, required: true)

  defp activity_breakdown(assigns) do
    ~H"""
    <section aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="text-lg font-semibold">{@title}</h2>
      <div class="mt-3 overflow-x-auto">
        <.dm_table id={@id} data={@rows} compact hover zebra>
          <:col :let={row} label={@key_label}>{row.key}</:col>
          <:col :let={row} label="Events">{row.event_count}</:col>
          <:col :let={row} label="Sessions">{row.session_count}</:col>
          <:col :let={row} label="Errors">{row.error_count}</:col>
        </.dm_table>
      </div>
    </section>
    """
  end

  defp reload(%{assigns: %{partition: nil}} = socket), do: socket

  defp reload(socket) do
    partition = socket.assigns.partition
    opts = activity_options(socket.assigns.filters)

    with {:ok, heatmap} <- Activity.heatmap(partition, opts),
         {:ok, trends} <- Activity.trends(partition, opts),
         {:ok, distribution} <-
           Activity.breakdown(
             partition,
             :event_type,
             Keyword.put(opts, :limit, @distribution_limit)
           ),
         {:ok, project_breakdown} <-
           Activity.breakdown(partition, :project, Keyword.put(opts, :limit, @distribution_limit)),
         {:ok, agent_breakdown} <-
           Activity.breakdown(
             partition,
             :agent_id,
             Keyword.put(opts, :limit, @distribution_limit)
           ),
         {:ok, host_breakdown} <-
           OperatorActivity.host_breakdown(
             Map.take(partition, [:client_id, :scope, :namespace]),
             Keyword.put(opts, :limit, @distribution_limit)
           ),
         {:ok, recent_events} <- Activity.recent_events(partition, Keyword.put(opts, :limit, 20)),
         {:ok, summary} <- Activity.summary(partition, opts) do
      last_page = distribution_pages(distribution)

      assign(socket,
        heatmap: heatmap,
        trends: trends,
        distribution: distribution,
        project_breakdown: project_breakdown,
        agent_breakdown: agent_breakdown,
        host_breakdown: host_breakdown,
        recent_events: recent_events,
        distribution_page: min(socket.assigns.distribution_page, last_page),
        summary: summary,
        query_error: nil
      )
    else
      {:error, reason} -> assign(socket, query_error: reason)
    end
  end

  defp activity_options(filters) do
    range = retention_range()

    [date_from: range.first, date_to: range.last]
    |> maybe_filter(:project, filters["project"])
    |> maybe_filter(:agent_id, filters["agent_id"])
    |> maybe_filter(:event_type, filters["event_type"])
  end

  defp maybe_filter(opts, _key, nil), do: opts
  defp maybe_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp retention_range do
    today = Date.utc_today()
    Date.range(Date.add(today, 1 - Config.activity_retention_days()), today)
  end

  defp normalize_filters(raw) when is_map(raw) do
    filters =
      raw
      |> Map.reject(fn {key, _value} -> String.starts_with?(key, "_unused_") end)
      |> Map.take(@filter_keys)
      |> Map.new(fn {key, value} -> {key, String.trim(value || "")} end)
      |> Map.reject(fn {_key, value} -> value == "" end)

    if Enum.all?(filters, fn {_key, value} -> valid_value?(value) end),
      do: {:ok, filters},
      else: {:error, :invalid_options}
  end

  defp normalize_filters(_raw), do: {:error, :invalid_options}
  defp valid_value?(value), do: is_binary(value) and value != "" and byte_size(value) <= 512

  defp relevant_update?(summary, partition, range) when is_map(summary) and is_map(partition) do
    Enum.all?(@partition_keys, fn key ->
      Map.get(summary, String.to_atom(key)) == Map.fetch!(partition, String.to_atom(key))
    end) and date_ranges_overlap?(summary[:date_from], summary[:date_to], range)
  end

  defp relevant_update?(_summary, _partition, _range), do: false

  defp date_ranges_overlap?(%Date{} = from, %Date{} = to, range),
    do: Date.compare(to, range.first) != :lt and Date.compare(from, range.last) != :gt

  defp date_ranges_overlap?(_from, _to, _range), do: false

  defp visible_distribution(assigns) do
    offset = (assigns.distribution_page - 1) * @distribution_page_size
    Enum.slice(assigns.distribution, offset, @distribution_page_size)
  end

  defp distribution_pages([]), do: 1

  defp distribution_pages(rows),
    do: rows |> length() |> Kernel./(@distribution_page_size) |> Float.ceil() |> trunc()

  defp load_partitions do
    case OperatorActivity.partitions(limit: 100) do
      {:ok, partitions} -> partitions
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp partition_options(partitions) do
    partitions
    |> Enum.with_index()
    |> Enum.map(fn {partition, index} ->
      label =
        Enum.join(
          [partition.host_id, partition.client_id, partition.scope, partition.namespace],
          " / "
        )

      {Integer.to_string(index), label}
    end)
  end

  defp aggregate_trends(rows, "daily") do
    Enum.map(rows, &Map.put(&1, :period, Date.to_iso8601(&1.date)))
  end

  defp aggregate_trends(rows, period) when period in ["monthly", "yearly"] do
    rows
    |> Enum.group_by(&period_key(&1.date, period))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, grouped} ->
      Enum.reduce(grouped, zero_trend(key), fn row, total ->
        Map.new(total, fn
          {:period, value} -> {:period, value}
          {counter, value} -> {counter, value + Map.fetch!(row, counter)}
        end)
      end)
    end)
  end

  defp period_key(date, "monthly"), do: "#{date.year}-#{pad(date.month)}"
  defp period_key(date, "yearly"), do: Integer.to_string(date.year)
  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp zero_trend(period) do
    %{
      period: period,
      event_count: 0,
      session_count: 0,
      memory_count: 0,
      lesson_count: 0,
      crystal_count: 0,
      recall_count: 0,
      action_count: 0,
      error_count: 0
    }
  end

  defp zero_summary do
    zero_trend("")
    |> Map.drop([:period])
    |> Map.merge(%{date_from: nil, date_to: nil})
  end

  defp heat_level(0), do: 0
  defp heat_level(count) when count < 3, do: 1
  defp heat_level(count) when count < 10, do: 2
  defp heat_level(_count), do: 3

  defp heat_class(count) do
    base = "block size-3 rounded-sm border border-outline-variant"

    color =
      case heat_level(count) do
        0 -> "bg-surface-container"
        1 -> "bg-primary/30"
        2 -> "bg-primary/60"
        3 -> "bg-primary"
      end

    [base, color]
  end

  defp host_health(%{host_id: host_id}) do
    case AgentManage.get_agent(host_id) do
      {:ok, entry} -> if(is_map(get_in(entry, [:runtime, :capture])), do: entry)
      {:error, :not_found} -> nil
    end
  end

  defp host_health(_partition), do: nil

  defp capture_value(entry, key, default) do
    capture = get_in(entry, [:runtime, :capture]) || %{}
    Map.get(capture, key, Map.get(capture, String.to_atom(key), default))
  end

  defp capture_state_label(%{status: :online} = entry) do
    entry
    |> capture_value("connection_state", "disconnected")
    |> to_string()
    |> String.capitalize()
  end

  defp capture_state_label(_entry), do: "Disconnected"
  defp agent_version(entry), do: get_in(entry, [:runtime, :agent_version]) || "—"

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1_024,
    do: "#{Float.round(bytes / 1_024, 1)} KiB"

  defp format_bytes(bytes) when is_number(bytes), do: "#{bytes} B"
  defp format_bytes(_bytes), do: "0 B"

  defp format_age(milliseconds) when is_number(milliseconds) and milliseconds >= 1_000,
    do: "#{div(trunc(milliseconds), 1_000)}s"

  defp format_age(milliseconds) when is_number(milliseconds), do: "#{trunc(milliseconds)}ms"
  defp format_age(_milliseconds), do: "0ms"

  defp format_latency(entry) do
    upload = capture_value(entry, "upload_latency_ms", nil)
    ack = capture_value(entry, "ack_latency_ms", nil)
    "#{format_milliseconds(upload)} / #{format_milliseconds(ack)}"
  end

  defp format_milliseconds(value) when is_number(value), do: "#{value} ms"
  defp format_milliseconds(_value), do: "—"
end
