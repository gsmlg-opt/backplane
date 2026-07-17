defmodule Backplane.Admin.MemoryEventsLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.Operations

  @memory_setting_keys [
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
       current_path: "/memory/events",
       rollout: Operations.rollout_state(),
       filters: %{},
       page: %{events: [], next_cursor: nil, filters: %{}},
       selected_event: nil,
       query_error: nil,
       new_events_available: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = Map.drop(params, ["event_id"])
    page_result = Operations.timeline(query)

    event_result =
      case socket.assigns.live_action do
        :show -> Operations.get_event(params["event_id"])
        :index -> {:ok, nil}
      end

    case {page_result, event_result} do
      {_page, {:error, :not_found}} ->
        {:noreply,
         socket
         |> put_flash(:error, "The selected event no longer exists.")
         |> push_navigate(to: ~p"/memory/events")}

      {{:ok, page}, {:ok, selected_event}} ->
        socket =
          assign(socket,
            page: page,
            filters: page.filters,
            selected_event: selected_event,
            query_error: nil,
            new_events_available: false
          )

        {:noreply, replace_event_query(socket, params, page.filters, false)}

      {{:error, {:invalid_param, _key, canonical}}, {:ok, _event}} ->
        {:noreply, replace_event_query(socket, params, canonical, true)}

      {{:error, reason}, _event} ->
        {:noreply, assign(socket, query_error: reason)}

      {_page, {:error, reason}} ->
        {:noreply, assign(socket, query_error: reason)}
    end
  end

  @impl true
  def handle_event("theme_changed", _params, socket), do: {:noreply, socket}

  def handle_event("filter", %{"filters" => raw} = params, socket) do
    normalized =
      raw
      |> merge_datetime_filter(params)
      |> Map.reject(fn {key, _value} -> String.starts_with?(key, "_unused_") end)
      |> Map.drop(["cursor"])
      |> Operations.normalize_timeline_params()

    {query, invalid?} =
      case normalized do
        {:ok, %{query: query}} -> {query, false}
        {:error, {:invalid_param, _key, query}} -> {query, true}
      end

    event_id =
      case socket.assigns.selected_event do
        %{id: event_id} -> event_id
        nil -> nil
      end

    socket =
      if invalid? do
        put_flash(socket, :error, "One invalid event parameter was removed.")
      else
        socket
      end

    {:noreply,
     push_patch(socket,
       to:
         events_path(
           socket.assigns.live_action,
           event_id,
           query
         ),
       replace: true
     )}
  end

  @impl true
  def handle_info({:memory_event_inserted, summary}, socket) do
    cond do
      not Operations.notification_matches?(summary, socket.assigns.filters) ->
        {:noreply, socket}

      is_nil(socket.assigns.filters["cursor"]) ->
        {:noreply, reload_events(socket)}

      true ->
        {:noreply, assign(socket, new_events_available: true)}
    end
  end

  def handle_info({:setting_changed, key, _value}, socket)
      when key in @memory_setting_keys do
    {:noreply, assign(socket, rollout: Operations.rollout_state())}
  end

  def handle_info({:setting_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#90
    ~H"""
    <div id="memory-events">
      <.memory_page_header
        title="Events"
        subtitle="Authoritative Memory V2 event explorer"
      />

      <.dm_alert
        :if={@query_error}
        id="event-query-error"
        variant="error"
        title="Events unavailable"
        compact
      >
        The last loaded event data is still shown. Retry after checking the
        database connection.
      </.dm_alert>

      <.dm_alert
        :if={@new_events_available}
        id="event-new-events"
        variant="info"
        title="New events available"
        compact
      >
        <.memory_link_button
          id="event-refresh-newest"
          patch={
            events_path(
              @live_action,
              @selected_event && @selected_event.id,
              Map.delete(@filters, "cursor")
            )
          }
          replace
          size="sm"
        >
          Refresh newest
        </.memory_link_button>
      </.dm_alert>

      <.form
        id="event-filters"
        for={%{}}
        as={:filters}
        phx-change="filter"
        phx-submit="filter"
        class="grid gap-3 sm:grid-cols-2 xl:grid-cols-5"
      >
        <.dm_input
          id="event-stream"
          name="filters[stream]"
          value={@filters["stream"]}
          label="Stream"
          phx-debounce="300"
        />
        <.dm_input
          id="event-project"
          name="filters[project]"
          value={@filters["project"]}
          label="Project"
          phx-debounce="300"
        />
        <.dm_input
          id="event-agent"
          name="filters[agent]"
          value={@filters["agent"]}
          label="Agent"
          phx-debounce="300"
        />
        <.dm_input
          id="event-session"
          name="filters[session]"
          value={@filters["session"]}
          label="Session"
          phx-debounce="300"
        />
        <.dm_input
          id="event-run"
          name="filters[run]"
          value={@filters["run"]}
          label="Run"
          phx-debounce="300"
        />
        <.dm_input
          id="event-type"
          name="filters[type]"
          value={@filters["type"]}
          label="Event type"
          phx-debounce="300"
        />
        <.dm_input
          id="event-tool"
          name="filters[tool]"
          value={@filters["tool"]}
          label="Tool"
          phx-debounce="300"
        />
        <.dm_input
          id="event-status"
          name="filters[status]"
          value={@filters["status"]}
          label="Status"
          phx-debounce="300"
        />
        <input type="hidden" name="filters[from]" value={@filters["from"]} />
        <.dm_input
          id="event-from"
          name="datetime_filters[from]"
          value={datetime_local_value(@filters["from"])}
          label="From (UTC)"
          type="datetime-local"
          step="any"
        />
        <input type="hidden" name="filters[to]" value={@filters["to"]} />
        <.dm_input
          id="event-to"
          name="datetime_filters[to]"
          value={datetime_local_value(@filters["to"])}
          label="To (UTC)"
          type="datetime-local"
          step="any"
        />
      </.form>

      <.memory_empty_state
        :if={@page.events == [] and is_nil(@selected_event)}
        title="No events match these filters"
        rollout={@rollout}
      />

      <div class={[
        "mt-4 grid min-w-0 gap-4",
        @selected_event &&
          "xl:grid-cols-[minmax(0,3fr)_minmax(22rem,2fr)]"
      ]}>
        <section class="min-w-0">
          <div class="overflow-x-auto">
            <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#91 --%>
            <.dm_table
              id="memory-events-table"
              data={@page.events}
              compact
              hover
              zebra
              class="min-w-[72rem]"
              phx-mounted={fix_dm_table_rowgroup_roles("memory-events-table")}
            >
              <:col :let={event} label="Event">
                <.link
                  href={event_detail_path(event.id, @filters)}
                  class="font-mono text-on-surface underline decoration-primary underline-offset-2 hover:decoration-2"
                >
                  {event.event_type}
                </.link>
              </:col>
              <:col :let={event} label="Stream / Sequence">
                <span class="font-mono text-xs">
                  {event.stream_id} · #{event.sequence}
                </span>
              </:col>
              <:col :let={event} label="Project / Agent">
                <span>{event.project || "—"}</span>
                <span class="block font-mono text-xs text-on-surface-variant">
                  {event.agent_id || "—"}
                </span>
              </:col>
              <:col :let={event} label="Tool">
                {event.tool_name || "—"}
              </:col>
              <:col :let={event} label="Status">
                <.status_badge status={event.status} />
              </:col>
              <:col :let={event} label="Occurred">
                {format_datetime(event.occurred_at)}
              </:col>
            </.dm_table>
          </div>

          <div class="mt-3 flex justify-end">
            <.memory_link_button
              :if={@page.next_cursor}
              id="event-load-older"
              patch={
                events_path(
                  @live_action,
                  @selected_event && @selected_event.id,
                  Map.put(@filters, "cursor", @page.next_cursor)
                )
              }
            >
              Load older
            </.memory_link_button>
          </div>
        </section>

        <aside :if={@selected_event} class="min-w-0">
          <.dm_card variant="bordered" padding="sm">
            <div class="mb-4 flex items-start justify-between gap-3">
              <div class="flex flex-wrap gap-2">
                <.event_type_badge event_type={@selected_event.event_type} />
                <.status_badge status={@selected_event.status} />
              </div>
              <.memory_link_button
                id="event-close-detail"
                patch={events_path(:index, nil, @filters)}
                size="sm"
                variant="ghost"
              >
                Close detail
              </.memory_link_button>
            </div>

            <dl
              id="event-identity"
              class="grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]"
            >
              <.identity_value label="Event ID" value={@selected_event.id} />
              <.identity_value label="Sequence" value={@selected_event.sequence} />
              <.identity_value
                label="Occurred"
                value={format_datetime(@selected_event.occurred_at)}
              />
              <.identity_value
                label="Persisted"
                value={format_datetime(@selected_event.inserted_at)}
              />
              <.identity_value label="Stream" value={@selected_event.stream_id} />
              <.identity_value label="Project" value={@selected_event.project} />
              <.identity_value label="Agent" value={@selected_event.agent_id} />
              <.identity_value label="Host" value={@selected_event.host_id} />
              <.identity_value label="Client" value={@selected_event.client_id} />
              <.identity_value label="Session" value={@selected_event.session_id} />
              <.identity_value label="Run" value={@selected_event.run_id} />
              <.identity_value label="Tool" value={@selected_event.tool_name} />
              <.identity_value label="Actor" value={@selected_event.actor_type} />
              <.identity_value label="Role" value={@selected_event.role} />
              <.identity_value label="Importance" value={@selected_event.importance} />
              <.identity_value label="Namespace" value={@selected_event.namespace} />
              <.identity_value
                label="Correlation"
                value={@selected_event.correlation_id}
              />
              <.identity_value
                label="Idempotency"
                value={@selected_event.idempotency_key}
              />
              <.identity_value
                label="Causation"
                value={@selected_event.causation_id}
              />
            </dl>

            <section class="mt-5">
              <h2 class="mb-2 font-semibold">Content</h2>
              <p
                id="event-content"
                class="whitespace-pre-wrap break-words text-sm"
              >
                {@selected_event.content || "—"}
              </p>
            </section>

            <section class="mt-5">
              <h2 class="mb-2 font-semibold">Payload</h2>
              <pre
                id="event-payload"
                class="max-h-[32rem] overflow-auto whitespace-pre-wrap break-all rounded-lg bg-surface-container-high p-3 font-mono text-xs text-on-surface"
              >{format_json(@selected_event.payload)}</pre>
            </section>
          </.dm_card>
        </aside>
      </div>
    </div>
    """
  end

  defp replace_event_query(socket, params, canonical, invalid?) do
    submitted = Map.drop(params, ["event_id"])

    if connected?(socket) and (invalid? or submitted != canonical) do
      socket =
        if invalid?,
          do:
            put_flash(
              socket,
              :error,
              "One invalid event parameter was removed."
            ),
          else: socket

      push_patch(socket,
        to:
          events_path(
            socket.assigns.live_action,
            params["event_id"],
            canonical
          ),
        replace: true
      )
    else
      socket
    end
  end

  defp events_path(:show, event_id, query) when is_binary(event_id) do
    ~p"/memory/events/#{event_id}?#{query}"
  end

  defp events_path(_action, _event_id, query) do
    ~p"/memory/events?#{query}"
  end

  defp event_detail_path(event_id, filters) do
    ~p"/memory/events/#{event_id}?#{filters}"
  end

  defp reload_events(socket) do
    with {:ok, page} <- Operations.timeline(socket.assigns.filters),
         {:ok, selected_event} <-
           reload_selected_event(socket.assigns.selected_event) do
      assign(socket,
        page: page,
        filters: page.filters,
        selected_event: selected_event,
        query_error: nil,
        new_events_available: false
      )
    else
      {:error, reason} ->
        assign(socket, query_error: reason)
    end
  end

  defp reload_selected_event(nil), do: {:ok, nil}

  defp reload_selected_event(selected) do
    case Operations.get_event(selected.id) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_datetime_filter(raw, %{"datetime_filters" => displayed}) do
    Enum.reduce(["from", "to"], raw, fn field, merged ->
      case Map.fetch(displayed, field) do
        {:ok, value} ->
          if value == datetime_local_value(Map.get(raw, field)) do
            merged
          else
            Map.put(merged, field, value)
          end

        :error ->
          merged
      end
    end)
  end

  defp merge_datetime_filter(raw, _params), do: raw
end
