defmodule Backplane.Admin.MemoryOverviewLive do
  @moduledoc "Memory V2 operational overview."

  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.Operations

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
    end

    {:ok,
     assign(socket,
       current_path: "/memory",
       regions: nil
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
end
