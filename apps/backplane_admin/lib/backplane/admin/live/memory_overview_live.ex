defmodule Backplane.Admin.MemoryOverviewLive do
  @moduledoc "Memory V2 operational overview."

  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.Operations
  alias Backplane.Memory.Operations.Repair
  alias Backplane.Memory.Privacy.Filter
  alias Backplane.Skills.AgentManage

  @memory_gate_keys [
    "memory.pipeline.enabled",
    "memory.events.enabled",
    "memory.events.dual_write"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Operations.subscribe_events()
      Operations.subscribe_rollout()
      AgentManage.subscribe()
    end

    {:ok,
     assign(socket,
       current_path: "/memory",
       regions: nil,
       repair_result: nil,
       capture_limit: 50,
       capture_agents: capture_agents()
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, regions: Operations.overview())}
  end

  @impl true
  def handle_info({:memory_event_inserted, _summary}, socket) do
    {:noreply, assign(socket, regions: Operations.overview())}
  end

  def handle_info({:setting_changed, key, _value}, socket)
      when key in @memory_gate_keys do
    {:noreply, assign(socket, regions: Operations.overview())}
  end

  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  def handle_info(:agents_changed, socket) do
    {:noreply, assign(socket, capture_agents: capture_agents())}
  end

  @impl true
  def handle_event("repair", %{"repair" => params}, socket) do
    partition = %{
      host_id: params["host_id"],
      client_id: params["client_id"],
      scope: params["scope"],
      namespace: params["namespace"]
    }

    args =
      params
      |> Map.drop(~w(host_id client_id scope namespace))
      |> Map.reject(fn {_key, value} -> value == "" end)

    result = Repair.run(args, partition, "admin:memory_operations")
    {:noreply, assign(socket, repair_result: result, regions: Operations.overview())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.memory_page_header
        title="Memory"
        subtitle="Authoritative streams, committed events, and guarded V2 rollout"
      />

      <.dm_card
        :if={is_nil(@regions)}
        id="memory-overview-loading"
        variant="bordered"
      >
        Loading Memory V2 operations…
      </.dm_card>

      <div :if={@regions} class="space-y-6">
        <.memory_region
          title="Rollout state"
          result={@regions.pipeline}
          :let={rollout}
        >
          <div class="grid gap-3 md:grid-cols-3">
            <.dm_card
              :for={gate <- [
                rollout.pipeline,
                rollout.events,
                rollout.dual_write
              ]}
              variant="bordered"
              padding="sm"
            >
              <h2 class="mb-3 font-semibold">{gate.label}</h2>
              <.gate_state_badges gate={gate} />
            </.dm_card>
          </div>

          <section class="mt-4" aria-label="Later stages">
            <h2 class="mb-2 font-semibold">Later stages</h2>
            <div class="flex flex-wrap gap-2">
              <.dm_badge
                :for={stage <- rollout.later}
                variant="neutral"
                size="sm"
              >
                {stage.label}: Unavailable
              </.dm_badge>
            </div>
          </section>
        </.memory_region>

        <.memory_region
          title="Host capture"
          result={{:ok, @capture_agents.entries}}
          :let={agents}
        >
          <.dm_card :if={agents == []} variant="bordered" padding="lg" class="text-center">
            <h2 class="text-lg font-semibold">No capture telemetry</h2>
            <p class="mt-2 text-sm text-on-surface-variant">
              Connected host agents have not reported capture health yet.
            </p>
          </.dm_card>

          <.dm_alert :if={@capture_agents.truncated?} id="memory-host-capture-truncated" variant="warning" title="Host capture list truncated" compact>
            Showing the first {@capture_limit} runtime snapshots.
          </.dm_alert>

          <div :if={agents != []} class="overflow-x-auto">
            <table id="memory-host-capture" class="min-w-full text-sm">
              <thead class="bg-surface-container-high text-on-surface">
                <tr>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Host</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Connection</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">
                    Integration version
                  </th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Last heartbeat</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Queue</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Oldest</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Captured</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Redacted</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Rejected</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Retries</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Dead letters</th>
                  <th scope="col" class="px-3 py-2 text-right font-semibold">Upload / ACK</th>
                  <th scope="col" class="px-3 py-2 text-left font-semibold">Health detail</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-outline-variant">
                <tr :for={entry <- agents} id={"memory-host-capture-#{entry.host.id}"}>
                  <td class="px-3 py-2 font-medium">{entry.host.name}</td>
                  <td class="px-3 py-2">
                    <.dm_badge variant={capture_state_variant(entry)} size="sm">
                      {capture_state_label(entry)}
                    </.dm_badge>
                  </td>
                  <td class="px-3 py-2 font-mono text-xs">{agent_version(entry)}</td>
                  <td class="px-3 py-2 text-xs">{format_datetime(entry.last_heartbeat_at)}</td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {metric_value(capture_value(entry, "spool_depth", nil))} / {format_bytes(
                      capture_value(entry, "spool_bytes", nil)
                    )}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {format_age(capture_value(entry, "oldest_event_age_ms", nil))}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {metric_value(capture_value(entry, "captured_count", nil))}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {metric_value(capture_value(entry, "redacted_count", nil))}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {metric_value(capture_value(entry, "rejected_count", nil))}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {metric_value(capture_value(entry, "retry_count", nil))}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {metric_value(capture_value(entry, "dead_letter_count", nil))}
                  </td>
                  <td class="px-3 py-2 text-right tabular-nums">
                    {format_latency(entry)}
                  </td>
                  <td class="px-3 py-2 text-xs">
                    <span>{capture_health_detail(entry)}</span>
                    <.link
                      href={~p"/system/host-agents/#{entry.host.id}"}
                      class="ml-2 text-primary underline"
                    >Inspect</.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.memory_region>

        <.memory_region
          title="Persisted activity"
          result={@regions.persisted_counts}
          :let={counts}
        >
          <.dm_card variant="bordered" padding="none">
            <div class="grid sm:grid-cols-2">
              <.dm_stat
                title="Open streams"
                value={Integer.to_string(counts.open_streams)}
              />
              <.dm_stat
                title="Events persisted in 24 hours"
                value={Integer.to_string(counts.events_last_24h)}
              />
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region title="Ingestion health" result={@regions.dashboard} :let={dashboard}>
          <.dm_card variant="bordered" padding="none">
            <div class="grid sm:grid-cols-2 lg:grid-cols-5">
              <.dm_stat title="Accepted (24h)" value={metric_value(dashboard.ingestion.accepted_24h)} />
              <.dm_stat title="Duplicates" value={sourced_value(dashboard.ingestion.duplicates)} />
              <.dm_stat title="Rejected" value={sourced_value(dashboard.ingestion.rejections)} />
              <.dm_stat title="Failures" value={sourced_value(dashboard.ingestion.failures)} />
              <.dm_stat title="Sequence gaps" value={metric_value(dashboard.ingestion.sequence_gaps)} />
            </div>
            <div class="flex gap-3 px-4 pb-4 text-sm">
              <.link href={~p"/memory/events"} class="text-primary underline">Inspect events</.link>
              <.link href={~p"/memory/streams"} class="text-primary underline">Inspect streams</.link>
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region title="Processing health" result={@regions.dashboard} :let={dashboard}>
          <div class="space-y-3">
            <.dm_card variant="bordered" padding="none">
              <div class="grid sm:grid-cols-2 lg:grid-cols-4">
                <.dm_stat title="Projection lag" value={lag_value(dashboard.processing.projection_lag)} />
                <.dm_stat title="Projection failures" value={metric_value(status_count(dashboard.processing.projections, ["failed", "dead_letter"]))} />
                <.dm_stat title="Circuit breaker" value={dashboard.processing.circuit_breaker.state |> to_string() |> String.capitalize()} />
                <.dm_stat title="Dead-letter jobs" value={metric_value(queue_total(dashboard.processing.queues, :dead_letters))} />
              </div>
            </.dm_card>

            <.dm_card variant="bordered" padding="none">
              <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6">
                <.dm_stat :for={{kind, count} <- dashboard.processing.backlogs} title={"#{humanize(kind)} backlog"} value={metric_value(count)} />
              </div>
            </.dm_card>

            <div class="overflow-x-auto">
              <table id="memory-processing-queues" class="min-w-full text-sm">
                <thead><tr><th class="px-3 py-2 text-left">Queue</th><th class="px-3 py-2 text-right">Depth</th><th class="px-3 py-2 text-right">Failures</th><th class="px-3 py-2 text-right">Dead letters</th></tr></thead>
                <tbody>
                  <tr :for={queue <- dashboard.processing.queues}>
                    <td class="px-3 py-2"><.link href={queue.detail_path} class="text-primary underline">{queue.queue}</.link></td>
                    <td class="px-3 py-2 text-right">{queue.depth}</td>
                    <td class="px-3 py-2 text-right">{queue.failures}</td>
                    <td class="px-3 py-2 text-right">{queue.dead_letters}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.dm_card :if={dashboard.processing.failed_workers != []} variant="bordered" padding="sm">
              <h3 class="font-semibold">Failed workers</h3>
              <ul class="mt-2 space-y-1 text-sm">
                <li :for={worker <- dashboard.processing.failed_workers}>
                  <.link href={worker.detail_path} class="text-primary underline">{worker.worker}</.link>
                  — {worker.queue} / {worker.state}
                </li>
              </ul>
            </.dm_card>

            <.link href={~p"/system/logs"} class="text-sm text-primary underline">Open background job logs</.link>
          </div>
        </.memory_region>

        <.memory_region title="Recall health" result={@regions.dashboard} :let={dashboard}>
          <.dm_card variant="bordered" padding="none">
            <div class="grid sm:grid-cols-2 lg:grid-cols-4">
              <.dm_stat title="Recall requests (24h)" value={metric_value(dashboard.recall.count)} />
              <.dm_stat title="Recall p50 / p95" value={latency_value(dashboard.recall.latency)} />
              <.dm_stat title="Empty recall rate" value={percent_value(dashboard.recall.empty_rate_percent)} />
              <.dm_stat title="Budget utilization" value={percent_value(dashboard.recall.budget_utilization_percent)} />
              <.dm_stat title="FTS / vector / graph" value={channel_value(dashboard.recall.channels)} />
              <.dm_stat title="Channel failures (FTS / vector / graph)" value={channel_failure_value(dashboard.recall.channel_failures)} />
              <.dm_stat title="Reranker used / failed" value={"#{dashboard.recall.reranker.used} / #{dashboard.recall.reranker.failures}"} />
              <.dm_stat title="Fallback rate" value={percent_value(dashboard.recall.fallback_rate_percent)} />
              <.dm_stat title="Estimated token reduction" value={estimated_token_value(dashboard.recall.estimated_token_reduction)} />
            </div>
            <p class="px-4 pb-2 text-xs text-on-surface-variant">This is an estimate, not provider usage.</p>
            <div class="border-t border-outline-variant px-4 py-3 text-sm">
              <strong>{dashboard.token_usage.label}:</strong>
              {actual_usage_value(dashboard.token_usage)}
              <.link href={~p"/memory/recall"} class="ml-3 text-primary underline">Inspect recall traces</.link>
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region title="Knowledge health" result={@regions.dashboard} :let={dashboard}>
          <.dm_card variant="bordered" padding="none">
            <div class="grid sm:grid-cols-2 lg:grid-cols-4">
              <.dm_stat title="Memory by type" value={count_map_value(dashboard.knowledge.memories_by_type)} />
              <.dm_stat title="Memory lifecycle" value={count_map_value(dashboard.knowledge.memories_by_lifecycle)} />
              <.dm_stat title="Lessons by state" value={count_map_value(dashboard.knowledge.lessons_by_state)} />
              <.dm_stat title="Crystals" value={metric_value(dashboard.knowledge.crystals)} />
              <.dm_stat title="Graph nodes / edges" value={"#{dashboard.knowledge.graph_nodes} / #{dashboard.knowledge.graph_edges}"} />
              <.dm_stat title="Pending contradictions" value={metric_value(dashboard.knowledge.pending_contradictions)} />
            </div>
            <div class="flex gap-3 px-4 pb-4 text-sm">
              <.link href={~p"/memory/lessons"} class="text-primary underline">Review lessons</.link>
              <.link href={~p"/memory/crystals"} class="text-primary underline">Review crystals</.link>
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region title="Coordination health" result={@regions.dashboard} :let={dashboard}>
          <.dm_card variant="bordered" padding="none">
            <div class="grid sm:grid-cols-2 lg:grid-cols-5">
              <.dm_stat title="Actions by status" value={count_map_value(dashboard.coordination.actions_by_status)} />
              <.dm_stat title="Frontier size" value={metric_value(dashboard.coordination.frontier_size)} />
              <.dm_stat title="Active leases" value={metric_value(dashboard.coordination.active_leases)} />
              <.dm_stat title="Expired leases" value={metric_value(dashboard.coordination.expired_leases)} />
              <.dm_stat title="Unread signals" value={metric_value(dashboard.coordination.unread_signals)} />
            </div>
          </.dm_card>
        </.memory_region>

        <section id="memory-repair-operations" aria-label="Repair operations">
          <.dm_card variant="bordered" padding="lg">
            <h2 class="text-lg font-semibold">Repair operations</h2>
            <p class="mt-1 text-sm text-on-surface-variant">
              Run one bounded, audited repair inside an exact trusted partition.
            </p>

            <.form for={%{}} as={:repair} phx-submit="repair" class="mt-4 grid gap-3 md:grid-cols-2 lg:grid-cols-4">
              <.dm_input id="repair-host" name="repair[host_id]" label="Host" value="" required />
              <.dm_input id="repair-client" name="repair[client_id]" label="Client" value="" required />
              <.dm_input id="repair-scope" name="repair[scope]" label="Scope" value="" required />
              <.dm_input id="repair-namespace" name="repair[namespace]" label="Namespace" value="" required />
              <.dm_select id="repair-kind" name="repair[kind]" label="Operation" value="failed_projections" options={Enum.map(Repair.kinds(), &{&1, humanize(&1)})} />
              <.dm_input id="repair-idempotency-key" name="repair[idempotency_key]" label="Idempotency key" value="" required />
              <.dm_input id="repair-target" name="repair[target_id]" label="Target ID" value="" />
              <.dm_input id="repair-session" name="repair[session_id]" label="Session ID" value="" />
              <.dm_input id="repair-project" name="repair[project]" label="Project" value="" />
              <.dm_select id="repair-resolution" name="repair[resolution]" label="Relation resolution" value="" options={[{"", "Not applicable"}, {"confirmed", "Confirmed"}, {"rejected", "Rejected"}]} />
              <.dm_select id="repair-action" name="repair[action]" label="Lesson action" value="" options={[{"", "Not applicable"}, {"promote", "Promote"}, {"archive", "Archive"}, {"dispute", "Dispute"}, {"supersede", "Supersede"}]} />
              <.dm_input id="repair-reason" name="repair[reason]" label="Reason" value="" />
              <.dm_input id="repair-date-from" name="repair[date_from]" type="date" label="Activity from" value="" />
              <.dm_input id="repair-date-to" name="repair[date_to]" type="date" label="Activity to" value="" />
              <div class="flex items-end">
                <.dm_btn type="submit" variant="primary">Run repair</.dm_btn>
              </div>
            </.form>

            <.dm_alert :if={match?({:ok, _}, @repair_result)} id="memory-repair-result" variant="success" title="Repair completed" compact>
              {repair_result_message(@repair_result)}
            </.dm_alert>
            <.dm_alert :if={match?({:error, _}, @repair_result)} id="memory-repair-error" variant="error" title="Repair failed" compact>
              {repair_result_message(@repair_result)}
            </.dm_alert>
          </.dm_card>
        </section>

        <.memory_region
          title="Persisted event volume"
          result={@regions.event_volume}
          :let={volume}
        >
          <.dm_card variant="bordered" padding="sm">
            <div
              id="memory-volume"
              class="grid h-28 grid-cols-[repeat(60,minmax(2px,1fr))] items-end gap-px"
            >
              <div
                :for={bucket <- volume}
                class="min-h-px rounded-t-sm bg-primary"
                data-bucket={DateTime.to_iso8601(bucket.at)}
                data-count={bucket.count}
                style={"height: #{volume_height(bucket.count, volume)}%"}
                title={"#{bucket.count} events at #{format_datetime(bucket.at)}"}
              />
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region
          title="Runtime ingestion"
          result={@regions.runtime_metrics}
          :let={metrics}
        >
          <.dm_card variant="bordered" padding="none">
            <p class="px-4 pt-4 text-sm text-on-surface-variant">
              Since process start
            </p>
            <div class="grid sm:grid-cols-3">
              <.dm_stat
                title="Appended"
                value={Integer.to_string(metrics.appended)}
              />
              <.dm_stat
                title="Duplicates"
                value={Integer.to_string(metrics.duplicates)}
              />
              <.dm_stat
                title="Errors"
                value={Integer.to_string(metrics.errors)}
                color={if metrics.errors > 0, do: "error", else: nil}
              />
            </div>
          </.dm_card>
        </.memory_region>

        <.memory_region
          title="Recent events"
          result={@regions.recent_events}
          :let={events}
        >
          <div class="overflow-x-auto">
            <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#91 --%>
            <.dm_table
              id="memory-recent-events"
              data={events}
              compact
              hover
              zebra
              class="min-w-[48rem]"
              phx-mounted={fix_dm_table_rowgroup_roles("memory-recent-events")}
            >
              <:col :let={event} label="Event">
                <.link
                  href={~p"/memory/events/#{event.id}"}
                  class="font-mono text-on-surface underline decoration-primary underline-offset-2 hover:decoration-2"
                >
                  {event.event_type}
                </.link>
              </:col>
              <:col :let={event} label="Stream">
                <span class="font-mono text-xs">{event.stream_id}</span>
              </:col>
              <:col :let={event} label="Occurred">
                {format_datetime(event.occurred_at)}
              </:col>
            </.dm_table>
          </div>
        </.memory_region>

        <.memory_region
          title="Active streams"
          result={@regions.active_streams}
          :let={streams}
        >
          <div class="overflow-x-auto">
            <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#91 --%>
            <.dm_table
              id="memory-active-streams"
              data={streams}
              compact
              hover
              zebra
              class="min-w-[48rem]"
              phx-mounted={fix_dm_table_rowgroup_roles("memory-active-streams")}
            >
              <:col :let={stream} label="Stream">
                <.link
                  href={~p"/memory/streams/#{stream.stream_id}"}
                  class="font-mono text-on-surface underline decoration-primary underline-offset-2 hover:decoration-2"
                >
                  {stream.stream_id}
                </.link>
              </:col>
              <:col :let={stream} label="Project">
                {stream.project || "—"}
              </:col>
              <:col :let={stream} label="Last activity">
                {format_datetime(stream.last_event_at)}
              </:col>
            </.dm_table>
          </div>
        </.memory_region>
      </div>
    </div>
    """
  end

  defp volume_height(count, volume) do
    max_count =
      volume
      |> Enum.map(& &1.count)
      |> Enum.max(fn -> 0 end)
      |> max(1)

    max(1, round(count / max_count * 100))
  end

  defp capture_agents do
    page = AgentManage.list_agents(limit: 50)

    %{
      page
      | entries:
          Enum.filter(page.entries, fn entry ->
            entry.status == :online or is_map(get_in(entry, [:runtime, :capture]))
          end)
    }
  end

  defp capture_value(entry, key, default) do
    capture = get_in(entry, [:runtime, :capture]) || %{}
    Map.get(capture, key, Map.get(capture, String.to_atom(key), default))
  end

  defp capture_state_label(entry) do
    entry
    |> capture_connection_state()
    |> to_string()
    |> String.capitalize()
  end

  defp capture_state_variant(entry) do
    case capture_connection_state(entry) do
      state when state in ["connected", :connected] -> "success"
      state when state in ["disabled", :disabled] -> "neutral"
      _state -> "warning"
    end
  end

  defp capture_connection_state(%{status: :online} = entry) do
    capture_value(entry, "connection_state", "disconnected")
  end

  defp capture_connection_state(_entry), do: "disconnected"

  defp agent_version(entry) do
    get_in(entry, [:runtime, :agent_version]) || "—"
  end

  defp format_bytes(bytes) when is_number(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KiB"
  end

  defp format_bytes(bytes) when is_number(bytes), do: "#{bytes} B"
  defp format_bytes(_bytes), do: "Unavailable"

  defp format_age(milliseconds) when is_number(milliseconds) and milliseconds >= 1_000 do
    "#{div(trunc(milliseconds), 1_000)}s"
  end

  defp format_age(milliseconds) when is_number(milliseconds), do: "#{trunc(milliseconds)}ms"
  defp format_age(_milliseconds), do: "Unavailable"

  defp format_latency(entry) do
    upload = capture_value(entry, "upload_latency_ms", nil)
    ack = capture_value(entry, "ack_latency_ms", nil)
    "#{format_milliseconds(upload)} / #{format_milliseconds(ack)}"
  end

  defp format_milliseconds(value) when is_number(value), do: "#{value} ms"
  defp format_milliseconds(_value), do: "Unavailable"

  defp capture_health_detail(%{last_error: error}) when is_binary(error) and error != "" do
    {:ok, safe_error} = Filter.apply_bounded(error, 2_048)
    safe_error
  end

  defp capture_health_detail(entry) do
    cond do
      capture_telemetry_unavailable?(entry) ->
        "Capture telemetry unavailable"

      capture_value(entry, "dead_letter_count", 0) > 0 ->
        "Dead letters require attention"

      capture_value(entry, "age_warning", false) == true ->
        "Oldest spool event is stale"

      capture_connection_state(entry) not in ["connected", :connected] ->
        "Capture channel unavailable"

      true ->
        "Healthy"
    end
  end

  defp capture_telemetry_unavailable?(entry) do
    Enum.any?(
      ~w(spool_depth spool_bytes oldest_event_age_ms captured_count redacted_count rejected_count retry_count dead_letter_count),
      &is_nil(capture_value(entry, &1, nil))
    )
  end

  defp metric_value(value) when is_integer(value), do: Integer.to_string(value)
  defp metric_value(value) when is_float(value), do: Float.to_string(value)
  defp metric_value(_value), do: "Unavailable"

  defp sourced_value(%{status: :available, value: value}), do: metric_value(value)
  defp sourced_value(_metric), do: "Unavailable"

  defp lag_value(%{status: :available, milliseconds: milliseconds}),
    do: format_age(milliseconds)

  defp lag_value(_lag), do: "Unavailable"

  defp status_count(counts, statuses),
    do: Enum.sum(Enum.map(statuses, &Map.get(counts, &1, 0)))

  defp queue_total(queues, field), do: Enum.sum(Enum.map(queues, &Map.fetch!(&1, field)))

  defp humanize(value),
    do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp latency_value(%{p50_ms: nil, p95_ms: nil}), do: "Unavailable"

  defp latency_value(%{p50_ms: p50, p95_ms: p95}),
    do: "#{format_milliseconds(p50)} / #{format_milliseconds(p95)}"

  defp percent_value(nil), do: "Unavailable"
  defp percent_value(value), do: "#{value}%"

  defp channel_value(channels) do
    [:fts, :vector, :graph]
    |> Enum.map(&Map.fetch!(channels, &1))
    |> Enum.map_join(" / ", &humanize/1)
  end

  defp channel_failure_value(failures) do
    [:fts, :vector, :graph]
    |> Enum.map_join(" / ", &Map.fetch!(failures, &1))
  end

  defp estimated_token_value(%{status: :estimated, tokens: tokens}),
    do: "≈#{tokens} tokens"

  defp estimated_token_value(_estimate), do: "Unavailable"

  defp actual_usage_value(%{status: :available} = usage),
    do:
      "#{usage.requests} requests, #{usage.input_tokens} input / #{usage.output_tokens} output tokens"

  defp actual_usage_value(_usage), do: "Unavailable"

  defp count_map_value(counts) when map_size(counts) == 0, do: "None"

  defp count_map_value(counts) do
    counts
    |> Enum.sort_by(fn {key, _count} -> key end)
    |> Enum.map_join(", ", fn {key, count} -> "#{key}: #{count}" end)
  end

  defp repair_result_message({:ok, result}) do
    "#{humanize(result.kind)}: #{result.status}; affected #{result.affected}"
  end

  defp repair_result_message({:error, reason}), do: humanize(reason)
  defp repair_result_message(nil), do: ""
end
