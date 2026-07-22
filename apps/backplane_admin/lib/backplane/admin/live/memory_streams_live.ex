defmodule Backplane.Admin.MemoryStreamsLive do
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
       current_path: "/memory/streams",
       rollout: Operations.rollout_state(),
       filters: %{},
       page: %{streams: [], next_cursor: nil, filters: %{}},
       selected_stream: nil,
       sequence_page: %{
         events: [],
         older_before: nil,
         newer_after: nil,
         window: :latest,
         params: %{}
       },
       query_error: nil,
       new_events_available: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    inventory_params =
      if socket.assigns.live_action == :show do
        Map.drop(params, ["stream_id", "before", "after"])
      else
        Map.drop(params, ["stream_id"])
      end

    sequence_params =
      if socket.assigns.live_action == :show,
        do: Map.take(params, ["before", "after"]),
        else: %{}

    inventory_result = Operations.list_streams(inventory_params)

    detail_result =
      case socket.assigns.live_action do
        :index ->
          {:ok, nil,
           %{
             events: [],
             older_before: nil,
             newer_after: nil,
             window: :latest,
             params: %{}
           }}

        :show ->
          with {:ok, stream} <- Operations.get_stream(params["stream_id"]),
               {:ok, sequence_page} <-
                 Operations.stream_events(stream.stream_id, sequence_params) do
            {:ok, stream, sequence_page}
          end
      end

    apply_stream_results(socket, params, inventory_result, detail_result)
  end

  @impl true
  def handle_event("filter", %{"filters" => raw}, socket) do
    normalized =
      raw
      |> Map.reject(fn {key, _value} -> String.starts_with?(key, "_unused_") end)
      |> Map.drop(["cursor", "before", "after"])
      |> Operations.normalize_stream_params()

    {query, invalid?} =
      case normalized do
        {:ok, %{query: query}} -> {query, false}
        {:error, {:invalid_param, _key, query}} -> {query, true}
      end

    stream_id =
      case socket.assigns.selected_stream do
        %{stream_id: stream_id} -> stream_id
        nil -> nil
      end

    socket =
      if invalid? do
        put_flash(socket, :error, "One invalid stream parameter was removed.")
      else
        socket
      end

    {:noreply,
     push_patch(socket,
       to:
         streams_path(
           socket.assigns.live_action,
           stream_id,
           query
         ),
       replace: true
     )}
  end

  @impl true
  def handle_info({:memory_event_inserted, summary}, socket) do
    reload_inventory? = is_nil(socket.assigns.filters["cursor"])

    reload_detail? =
      match?(
        %{stream_id: stream_id} when stream_id == summary.stream_id,
        socket.assigns.selected_stream
      ) and socket.assigns.sequence_page.window == :latest

    socket =
      if reload_inventory?,
        do: reload_stream_inventory(socket),
        else: assign(socket, new_events_available: true)

    socket =
      case socket.assigns.selected_stream do
        %{stream_id: stream_id}
        when stream_id == summary.stream_id and reload_detail? ->
          reload_latest_stream_detail(socket)

        %{stream_id: stream_id} when stream_id == summary.stream_id ->
          assign(socket, new_events_available: true)

        _other ->
          socket
      end

    {:noreply, socket}
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
    <div id="memory-streams">
      <.memory_page_header
        title="Streams"
        subtitle="Authoritative Memory V2 stream inventory"
      />

      <.dm_alert
        :if={@query_error}
        id="stream-query-error"
        variant="error"
        title="Streams unavailable"
        compact
      >
        The last loaded stream data is still shown. Retry after checking the
        database connection.
      </.dm_alert>

      <.dm_alert
        :if={@new_events_available}
        id="stream-new-events"
        variant="info"
        title="New events available"
        compact
      >
        <.memory_link_button
          id="stream-refresh-newest"
          patch={
            streams_path(
              @live_action,
              @selected_stream && @selected_stream.stream_id,
              Map.drop(@filters, ["cursor"])
            )
          }
          replace
          size="sm"
        >
          Refresh newest
        </.memory_link_button>
      </.dm_alert>

      <.form
        id="stream-filters"
        for={%{}}
        as={:filters}
        phx-change="filter"
        phx-submit="filter"
        class="grid gap-3 sm:grid-cols-2 xl:grid-cols-6"
      >
        <.dm_select
          id="stream-state"
          name="filters[state]"
          value={@filters["state"]}
          label="State"
          options={[
            {"", "All states"},
            {"open", "Open"},
            {"closed", "Closed"}
          ]}
        />
        <.dm_input
          id="stream-project"
          name="filters[project]"
          value={@filters["project"]}
          label="Project"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-agent"
          name="filters[agent]"
          value={@filters["agent"]}
          label="Agent"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-host"
          name="filters[host]"
          value={@filters["host"]}
          label="Host"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-session"
          name="filters[session]"
          value={@filters["session"]}
          label="Session"
          phx-debounce="300"
        />
        <.dm_input
          id="stream-run"
          name="filters[run]"
          value={@filters["run"]}
          label="Run"
          phx-debounce="300"
        />
      </.form>

      <.memory_empty_state
        :if={is_nil(@query_error) and @page.streams == [] and is_nil(@selected_stream)}
        title="No streams match these filters"
        rollout={@rollout}
      />

      <div class={[
        "mt-4 grid min-w-0 gap-4",
        @selected_stream &&
          "xl:grid-cols-[minmax(0,3fr)_minmax(22rem,2fr)]"
      ]}>
        <section class="min-w-0">
          <div class="overflow-x-auto">
            <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#91 --%>
            <.dm_table
              id="memory-streams-table"
              data={@page.streams}
              compact
              hover
              zebra
              class="min-w-[64rem]"
              phx-mounted={fix_dm_table_rowgroup_roles("memory-streams-table")}
            >
              <:col :let={stream} label="Stream">
                <.link
                  href={stream_detail_path(stream.stream_id, @filters)}
                  class="font-mono text-on-surface underline decoration-primary underline-offset-2 hover:decoration-2"
                >
                  {stream.stream_id}
                </.link>
              </:col>
              <:col :let={stream} label="Project">
                {stream.project || "—"}
              </:col>
              <:col :let={stream} label="Session / Run">
                <span class="font-mono text-xs">
                  {stream.session_id || stream.run_id || "—"}
                </span>
              </:col>
              <:col :let={stream} label="Sequence">
                <span class="font-mono">
                  {max(stream.next_sequence - 1, 0)}
                </span>
              </:col>
              <:col :let={stream} label="Last activity">
                {format_datetime(stream.last_event_at)}
              </:col>
              <:col :let={stream} label="State">
                <.dm_badge
                  variant={if stream.closed_at, do: "neutral", else: "success"}
                >
                  {if stream.closed_at, do: "Closed", else: "Open"}
                </.dm_badge>
              </:col>
            </.dm_table>
          </div>

          <div class="mt-3 flex justify-end">
            <.memory_link_button
              :if={@page.next_cursor}
              id="stream-next-page"
              patch={
                streams_path(
                  @live_action,
                  @selected_stream && @selected_stream.stream_id,
                  @filters
                  |> Map.merge(@sequence_page.params)
                  |> Map.put("cursor", @page.next_cursor)
                )
              }
            >
              Next page
            </.memory_link_button>
          </div>
        </section>

        <aside :if={@selected_stream} class="min-w-0">
          <.dm_card variant="bordered" padding="sm">
            <div class="mb-4 flex items-center justify-between gap-3">
              <.dm_badge
                variant={
                  if @selected_stream.closed_at,
                    do: "neutral",
                    else: "success"
                }
              >
                {if @selected_stream.closed_at, do: "Closed", else: "Open"}
              </.dm_badge>
              <.memory_link_button
                id="stream-close-detail"
                patch={streams_path(:index, nil, @filters)}
                size="sm"
                variant="ghost"
              >
                Close detail
              </.memory_link_button>
            </div>

            <dl
              id="stream-identity"
              class="grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]"
            >
              <.identity_value label="Stream ID" value={@selected_stream.stream_id} />
              <.identity_value label="Project" value={@selected_stream.project} />
              <.identity_value label="Agent" value={@selected_stream.agent_id} />
              <.identity_value label="Host" value={@selected_stream.host_id} />
              <.identity_value label="Client" value={@selected_stream.client_id} />
              <.identity_value label="Session" value={@selected_stream.session_id} />
              <.identity_value label="Run" value={@selected_stream.run_id} />
              <.identity_value
                label="First activity"
                value={format_datetime(@selected_stream.inserted_at)}
              />
              <.identity_value
                label="Last activity"
                value={format_datetime(@selected_stream.last_event_at)}
              />
              <.identity_value
                label="Closed at"
                value={format_datetime(@selected_stream.closed_at)}
              />
              <.identity_value
                label="Current sequence"
                value={max(@selected_stream.next_sequence - 1, 0)}
              />
            </dl>

            <.dm_timeline id="stream-sequence" size="sm" class="mt-5">
              <:item
                :for={event <- @sequence_page.events}
                title={"##{event.sequence} · #{event.event_type}"}
                time={format_datetime(event.occurred_at)}
                color={event_color(event)}
              >
                <span class="break-words text-sm">{event.content}</span>
              </:item>
            </.dm_timeline>

            <div class="mt-4 flex flex-wrap gap-2">
              <.memory_link_button
                :if={@sequence_page.older_before}
                id="stream-older-events"
                patch={
                  streams_path(
                    :show,
                    @selected_stream.stream_id,
                    @filters
                    |> Map.delete("after")
                    |> Map.put("before", @sequence_page.older_before)
                  )
                }
              >
                Older events
              </.memory_link_button>
              <.memory_link_button
                :if={@sequence_page.newer_after}
                id="stream-newer-events"
                patch={
                  streams_path(
                    :show,
                    @selected_stream.stream_id,
                    @filters
                    |> Map.delete("before")
                    |> Map.put("after", @sequence_page.newer_after)
                  )
                }
              >
                Newer events
              </.memory_link_button>
            </div>
          </.dm_card>
        </aside>
      </div>
    </div>
    """
  end

  defp apply_stream_results(
         socket,
         params,
         {:ok, page},
         {:ok, selected_stream, sequence_page}
       ) do
    canonical = Map.merge(page.filters, sequence_page.params)

    socket =
      assign(socket,
        page: page,
        filters: page.filters,
        selected_stream: selected_stream,
        sequence_page: sequence_page,
        query_error: nil,
        new_events_available: false
      )

    {:noreply, replace_stream_query(socket, params, canonical, false)}
  end

  defp apply_stream_results(
         socket,
         params,
         {:error, {:invalid_param, _key, inventory_query}},
         {:ok, _stream, sequence_page}
       ) do
    {:noreply,
     replace_stream_query(
       socket,
       params,
       Map.merge(inventory_query, sequence_page.params),
       true
     )}
  end

  defp apply_stream_results(
         socket,
         params,
         {:ok, page},
         {:error, {:invalid_param, _key, sequence_query}}
       ) do
    {:noreply,
     replace_stream_query(
       socket,
       params,
       Map.merge(page.filters, sequence_query),
       true
     )}
  end

  defp apply_stream_results(
         socket,
         params,
         {:error, {:invalid_param, _key, inventory_query}},
         {:error, {:invalid_param, _other_key, sequence_query}}
       ) do
    {:noreply,
     replace_stream_query(
       socket,
       params,
       Map.merge(inventory_query, sequence_query),
       true
     )}
  end

  defp apply_stream_results(socket, _params, _inventory, {:error, :not_found}) do
    {:noreply,
     socket
     |> put_flash(:error, "The selected stream no longer exists.")
     |> push_navigate(to: ~p"/memory/streams")}
  end

  defp apply_stream_results(socket, _params, {:error, reason}, _detail) do
    {:noreply, assign(socket, query_error: reason)}
  end

  defp apply_stream_results(socket, _params, _inventory, {:error, reason}) do
    {:noreply, assign(socket, query_error: reason)}
  end

  defp replace_stream_query(socket, params, canonical, invalid?) do
    submitted = Map.drop(params, ["stream_id"])

    if connected?(socket) and (invalid? or submitted != canonical) do
      socket =
        if invalid?,
          do:
            put_flash(
              socket,
              :error,
              "One invalid stream parameter was removed."
            ),
          else: socket

      push_patch(socket,
        to:
          streams_path(
            socket.assigns.live_action,
            params["stream_id"],
            canonical
          ),
        replace: true
      )
    else
      socket
    end
  end

  defp streams_path(:show, stream_id, query) when is_binary(stream_id) do
    ~p"/memory/streams/#{stream_id}?#{query}"
  end

  defp streams_path(_action, _stream_id, query) do
    ~p"/memory/streams?#{query}"
  end

  defp stream_detail_path(stream_id, filters) do
    ~p"/memory/streams/#{stream_id}?#{filters}"
  end

  defp reload_stream_inventory(socket) do
    case Operations.list_streams(socket.assigns.filters) do
      {:ok, page} ->
        assign(socket,
          page: page,
          filters: page.filters,
          query_error: nil,
          new_events_available: false
        )

      {:error, reason} ->
        assign(socket, query_error: reason)
    end
  end

  defp reload_latest_stream_detail(socket) do
    stream_id = socket.assigns.selected_stream.stream_id

    with {:ok, stream} <- Operations.get_stream(stream_id),
         {:ok, sequence_page} <- Operations.stream_events(stream_id, %{}) do
      assign(socket,
        selected_stream: stream,
        sequence_page: sequence_page
      )
    else
      {:error, :not_found} ->
        assign(socket, selected_stream: nil)

      {:error, reason} ->
        assign(socket, query_error: reason)
    end
  end
end
