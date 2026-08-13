defmodule Backplane.Admin.MemoryReplayLive do
  @moduledoc """
  Exact-partition historical replay for the trusted admin surface.

  The intentionally open admin router establishes its trusted-operator boundary
  with separate `memory_replay_authorized` and
  `memory_replay_detail_authorized` booleans in the signed LiveView session.
  Both capabilities fail closed when absent; query parameters and caller payloads
  cannot grant either capability. Keeping them separate allows payload detail to
  be restricted later without disabling privacy-filtered playback metadata.
  """

  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents

  alias Backplane.Memory.{Replay, ReplayNotifier}

  @partition_params ~w(host client scope namespace)
  @speeds [0.5, 1.0, 2.0, 4.0]
  @page_size 100
  @max_events 1_000
  @base_interval_ms 1_000
  @source_kinds ~w(summary memory graph action)

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: ReplayNotifier.subscribe()

    authorized? = Map.get(session, "memory_replay_authorized", false) == true

    socket =
      assign(socket,
        current_path: "/memory/replay",
        authorized?: authorized?,
        detail_authorized?: Map.get(session, "memory_replay_detail_authorized", false) == true,
        partition: nil,
        session_id: nil,
        events: [],
        kinds: [],
        active_kinds: MapSet.new(),
        selected_event_id: nil,
        selected_source: nil,
        source_error: nil,
        playing?: false,
        speed: 1.0,
        playback_generation: 0,
        query_error: nil,
        truncated?: false
      )

    initial_params = Map.get(session, "memory_replay_params", params)
    {:ok, maybe_load(socket, initial_params)}
  end

  @impl true
  def handle_event("select_partition", %{"replay" => params}, socket) do
    if socket.router do
      query =
        params
        |> Map.take(@partition_params ++ ["session"])
        |> Map.new(fn {key, value} -> {key, String.trim(value || "")} end)

      {:noreply, push_navigate(socket, to: "/memory/replay?" <> URI.encode_query(query))}
    else
      {:noreply, maybe_load(socket, params)}
    end
  end

  def handle_event("toggle_playback", _params, socket) do
    if playable?(socket) do
      playing? = not socket.assigns.playing?
      socket = invalidate_timer(socket, playing?)
      {:noreply, if(playing?, do: schedule_tick(socket), else: socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("previous", _params, socket), do: {:noreply, move(socket, -1)}
  def handle_event("next", _params, socket), do: {:noreply, move(socket, 1)}

  def handle_event("scrub", %{"playback" => %{"position" => raw}}, socket) do
    {:noreply, select_index(socket, parse_position(raw) - 1)}
  end

  def handle_event("set_speed", %{"speed" => raw}, socket) do
    case Float.parse(raw) do
      {speed, ""} when speed in @speeds ->
        socket = invalidate_timer(socket, socket.assigns.playing?)
        socket = assign(socket, speed: speed)
        {:noreply, if(socket.assigns.playing?, do: schedule_tick(socket), else: socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "restore_view",
        %{"selected_event_id" => event_id, "active_kinds" => kinds, "speed" => raw_speed},
        socket
      )
      when is_binary(event_id) and is_list(kinds) and is_binary(raw_speed) do
    with true <- Enum.all?(kinds, &(&1 in socket.assigns.kinds)),
         {speed, ""} when speed in @speeds <- Float.parse(raw_speed) do
      socket =
        socket
        |> invalidate_timer(false)
        |> assign(
          active_kinds: MapSet.new(kinds),
          speed: speed,
          selected_event_id: event_id,
          selected_source: nil,
          source_error: nil
        )
        |> preserve_or_select_first()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_kind", %{"kind" => kind}, socket) do
    if kind in socket.assigns.kinds do
      active = socket.assigns.active_kinds

      active =
        if MapSet.member?(active, kind),
          do: MapSet.delete(active, kind),
          else: MapSet.put(active, kind)

      {:noreply,
       socket
       |> invalidate_timer(false)
       |> assign(active_kinds: active, selected_source: nil, source_error: nil)
       |> preserve_or_select_first()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_event", %{"event-id" => event_id}, socket) do
    if Enum.any?(filtered_events(socket), &(&1.event_id == event_id)) do
      {:noreply,
       socket
       |> invalidate_timer(false)
       |> assign(selected_event_id: event_id, selected_source: nil, source_error: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "select_source",
        %{"event-id" => event_id, "kind" => kind, "source-id" => source_id},
        socket
      ) do
    with true <- socket.assigns.detail_authorized?,
         true <- kind in @source_kinds,
         %{links: links} <- Enum.find(socket.assigns.events, &(&1.event_id == event_id)),
         ids when is_list(ids) <- Map.get(links, String.to_existing_atom(kind)),
         true <- source_id in Enum.map(ids, &to_string/1) do
      {:noreply,
       assign(socket,
         selected_event_id: event_id,
         selected_source: %{event_id: event_id, kind: kind, id: source_id},
         source_error: nil
       )}
    else
      _ -> {:noreply, assign(socket, selected_source: nil, source_error: :not_linked)}
    end
  end

  def handle_event("keyboard", %{"key" => key}, socket) do
    socket =
      case key do
        "ArrowLeft" -> move(socket, -1)
        "ArrowRight" -> move(socket, 1)
        "Home" -> select_index(socket, 0)
        "End" -> select_index(socket, length(filtered_events(socket)) - 1)
        " " -> toggle_from_keyboard(socket)
        "Spacebar" -> toggle_from_keyboard(socket)
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:replay_tick, generation}, socket) do
    if socket.assigns.playing? and generation == socket.assigns.playback_generation do
      events = filtered_events(socket)
      index = selected_index(socket, events)

      if index < length(events) - 1 do
        {:noreply, socket |> select_index(index + 1) |> schedule_tick()}
      else
        {:noreply, invalidate_timer(socket, false)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:memory_replay_updated, %{"session_id" => session_id}}, socket) do
    if session_id == socket.assigns.session_id and socket.assigns.partition do
      {:noreply, reload(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        filtered_events: filtered_events(assigns),
        selected_event: selected_event(assigns),
        selected_position: selected_position(assigns),
        speeds: @speeds,
        max_events: @max_events
      )

    ~H"""
    <div
      id="memory-replay"
      phx-hook="ReplayKeyboard"
      data-state-key={replay_state_key(@partition, @session_id)}
      data-selected-event-id={@selected_event_id}
      data-active-kinds={Jason.encode!(MapSet.to_list(@active_kinds))}
      data-speed={@speed}
    >
      <.memory_page_header title="Replay" subtitle="Privacy-filtered historical playback for one exact partition and session" />

      <.dm_alert :if={!@authorized?} id="replay-unauthorized" variant="error" title="Replay unavailable" compact>
        Trusted operator access is required.
      </.dm_alert>

      <div :if={@authorized?}>
        <.form id="replay-selector" for={%{}} as={:replay} phx-submit="select_partition" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <.dm_input id="replay-host" name="replay[host]" label="Host" value={partition_value(@partition, :host_id)} required />
          <.dm_input id="replay-client" name="replay[client]" label="Client" value={partition_value(@partition, :client_id)} required />
          <.dm_input id="replay-scope" name="replay[scope]" label="Scope" value={partition_value(@partition, :scope)} required />
          <.dm_input id="replay-namespace" name="replay[namespace]" label="Namespace" value={partition_value(@partition, :namespace)} required />
          <.dm_input id="replay-session" name="replay[session]" label="Session" value={@session_id || ""} required />
          <div class="sm:col-span-2 lg:col-span-5"><.dm_btn type="submit" variant="primary">Load replay</.dm_btn></div>
        </.form>

        <.dm_alert :if={@query_error} id="replay-query-error" variant="error" title="Replay unavailable" compact class="mt-4">
          The exact partition and session could not be loaded.
        </.dm_alert>

        <.dm_alert :if={@truncated?} id="replay-truncated" variant="warning" title="Replay truncated" compact class="mt-4">
          This view is limited to the first {@max_events} events.
        </.dm_alert>

        <section :if={@partition && !@query_error} id="replay-player" class="mt-6" aria-label="Replay player">
          <div class="flex flex-wrap items-center gap-2">
            <button id="replay-previous" type="button" class="btn btn-sm" phx-click="previous" disabled={@filtered_events == []}>Previous</button>
            <button id="replay-play-pause" type="button" class="btn btn-primary btn-sm" phx-click="toggle_playback" aria-pressed={to_string(@playing?)} disabled={@filtered_events == []}>{if @playing?, do: "Pause", else: "Play"}</button>
            <button id="replay-next" type="button" class="btn btn-sm" phx-click="next" disabled={@filtered_events == []}>Next</button>

            <span class="ml-2 text-sm font-medium">Speed</span>
            <button :for={speed <- @speeds} id={"replay-speed-#{speed_id(speed)}"} type="button" class="btn btn-sm" phx-click="set_speed" phx-value-speed={speed} data-speed={speed_id(speed)} aria-pressed={to_string(@speed == speed)}>{speed_id(speed)}×</button>
          </div>

          <.form id="replay-scrubber-form" for={%{}} as={:playback} phx-change="scrub" class="mt-4">
            <label for="replay-scrubber" class="text-sm font-medium">Timeline position {@selected_position} of {length(@filtered_events)}</label>
            <input id="replay-scrubber" type="range" name="playback[position]" min="1" max={max(length(@filtered_events), 1)} value={max(@selected_position, 1)} disabled={@filtered_events == []} class="mt-2 w-full" />
          </.form>

          <fieldset id="replay-kind-filters" class="mt-4">
            <legend class="text-sm font-medium">Event kinds</legend>
            <div class="mt-2 flex flex-wrap gap-2">
              <button :for={kind <- @kinds} id={"replay-kind-#{kind}"} type="button" class="btn btn-sm" phx-click="toggle_kind" phx-value-kind={kind} data-kind={kind} aria-pressed={to_string(MapSet.member?(@active_kinds, kind))}>{kind}</button>
            </div>
          </fieldset>

          <div class="mt-5 grid gap-5 lg:grid-cols-[minmax(16rem,0.8fr)_minmax(0,1.2fr)]">
            <ol id="replay-events" class="max-h-[36rem] space-y-2 overflow-y-auto" aria-label="Replay events">
              <li :for={event <- @filtered_events}>
                <button id={"replay-event-#{event.position}"} type="button" class="w-full rounded-lg border border-outline-variant p-3 text-left" phx-click="select_event" phx-value-event-id={event.event_id} aria-current={to_string(event.event_id == @selected_event_id)}>
                  <span class="font-mono text-xs">#{event.position}</span>
                  <span class="ml-2 font-medium">{event.kind}</span>
                  <time class="mt-1 block text-xs text-on-surface-variant">{format_datetime(event.occurred_at)}</time>
                </button>
              </li>
            </ol>

            <div>
              <.dm_card :if={@selected_event} id="replay-event-detail" variant="bordered" padding="sm">
                <div class="flex flex-wrap items-center gap-2">
                  <h2 class="text-lg font-semibold">Event {@selected_event.position}</h2>
                  <.event_type_badge event_type={@selected_event.event_type} />
                </div>
                <dl class="mt-3 grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]">
                  <.identity_value label="Event ID" value={@selected_event.event_id} />
                  <.identity_value label="Kind" value={@selected_event.kind} />
                  <.identity_value label="Occurred at" value={format_datetime(@selected_event.occurred_at)} />
                </dl>

                <div :if={@detail_authorized?}>
                  <h3 class="mt-4 font-semibold">Privacy-filtered detail</h3>
                  <pre id="replay-detail-json" class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-surface-container p-3 text-xs">{format_json(@selected_event.detail)}</pre>
                  <.derived_links event={@selected_event} partition={@partition} />
                </div>
                <.dm_alert :if={!@detail_authorized?} id="replay-detail-denied" variant="warning" title="Detail restricted" compact class="mt-4">
                  Playback metadata is visible, but payload detail requires an additional permission.
                </.dm_alert>
              </.dm_card>

              <.dm_alert :if={@source_error} id="replay-source-error" variant="error" title="Source unavailable" compact class="mt-4">
                The requested source is not linked to this replay event.
              </.dm_alert>

              <.dm_card :if={@selected_source} id="replay-source-detail" variant="bordered" padding="sm" class="mt-4">
                <h2 class="font-semibold">Selected derived source</h2>
                <dl class="mt-3 grid grid-cols-1 gap-x-4 gap-y-2 sm:grid-cols-[max-content_minmax(0,1fr)]">
                  <.identity_value label="Kind" value={@selected_source.kind} />
                  <.identity_value label="Source ID" value={@selected_source.id} />
                  <.identity_value label="Linked event" value={@selected_source.event_id} />
                  <.identity_value label="Host" value={@partition.host_id} />
                  <.identity_value label="Client" value={@partition.client_id} />
                  <.identity_value label="Scope" value={@partition.scope} />
                  <.identity_value label="Namespace" value={@partition.namespace} />
                </dl>
              </.dm_card>
            </div>
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr(:event, :map, required: true)
  attr(:partition, :map, required: true)

  defp derived_links(assigns) do
    assigns = assign(assigns, :partition_query, partition_query(assigns.partition))

    ~H"""
    <section id={"replay-event-#{@event.position}-links"} class="mt-4">
      <h3 class="font-semibold">Derived sources</h3>
      <div class="mt-2 flex flex-wrap gap-2 text-sm">
        <span :for={{kind, ids} <- @event.links} class="contents">
          <.link :for={id <- ids} :if={kind == :lesson} navigate={"/memory/lessons/#{URI.encode(to_string(id))}?" <> URI.encode_query(@partition_query)} class="text-primary underline">lesson {id}</.link>
          <.link :for={id <- ids} :if={kind == :crystal} navigate={"/memory/crystals/#{URI.encode(to_string(id))}?" <> URI.encode_query(@partition_query)} class="text-primary underline">crystal {id}</.link>
          <button :for={id <- ids} :if={kind not in [:lesson, :crystal]} id={source_control_id(@event.position, kind, id)} type="button" class="font-mono text-primary underline" phx-click="select_source" phx-value-event-id={@event.event_id} phx-value-kind={kind} phx-value-source-id={id}>{kind} {id}</button>
        </span>
        <span :if={Enum.all?(@event.links, fn {_kind, ids} -> ids == [] end)} class="text-on-surface-variant">None</span>
      </div>
    </section>
    """
  end

  defp maybe_load(socket, params) when is_map(params) do
    cond do
      not socket.assigns.authorized? -> socket
      map_size(Map.take(params, @partition_params ++ ["session"])) == 0 -> socket
      true -> load(socket, params)
    end
  end

  defp load(socket, params) do
    with {:ok, partition, session_id} <- selector(params),
         {:ok, events, truncated?} <- load_all(partition, session_id) do
      kinds = events |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

      socket
      |> invalidate_timer(false)
      |> assign(
        partition: partition,
        session_id: session_id,
        events: events,
        kinds: kinds,
        active_kinds: MapSet.new(kinds),
        selected_event_id: events |> List.first() |> event_id(),
        selected_source: nil,
        source_error: nil,
        query_error: nil,
        truncated?: truncated?
      )
    else
      {:error, reason} ->
        socket
        |> invalidate_timer(false)
        |> assign(
          partition: nil,
          session_id: nil,
          events: [],
          kinds: [],
          active_kinds: MapSet.new(),
          selected_event_id: nil,
          selected_source: nil,
          source_error: nil,
          query_error: reason,
          truncated?: false
        )
    end
  end

  defp reload(socket) do
    selected_event_id = socket.assigns.selected_event_id
    active_kinds = socket.assigns.active_kinds
    all_kinds_active? = active_kinds == MapSet.new(socket.assigns.kinds)
    selected_source = socket.assigns.selected_source

    case load_all(socket.assigns.partition, socket.assigns.session_id) do
      {:ok, events, truncated?} ->
        kinds = events |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

        active_kinds =
          if all_kinds_active?,
            do: MapSet.new(kinds),
            else: MapSet.intersection(active_kinds, MapSet.new(kinds))

        socket
        |> invalidate_timer(false)
        |> assign(
          events: events,
          kinds: kinds,
          active_kinds: active_kinds,
          selected_event_id: selected_event_id,
          selected_source: valid_selected_source(selected_source, events),
          source_error: nil,
          query_error: nil,
          truncated?: truncated?
        )
        |> preserve_or_select_first()

      {:error, reason} ->
        socket |> invalidate_timer(false) |> assign(query_error: reason)
    end
  end

  defp selector(params) do
    values = Map.new(@partition_params ++ ["session"], &{&1, String.trim(params[&1] || "")})

    if Enum.all?(values, fn {_key, value} -> value != "" and byte_size(value) <= 512 end) do
      {:ok,
       %{
         host_id: values["host"],
         client_id: values["client"],
         scope: values["scope"],
         namespace: values["namespace"]
       }, values["session"]}
    else
      {:error, :partition_required}
    end
  end

  defp load_all(partition, session_id),
    do: load_pages(partition, session_id, nil, [], @max_events)

  defp load_pages(partition, session_id, cursor, acc, remaining) do
    limit = min(@page_size, remaining)

    with {:ok, %{events: events, next_cursor: next_cursor}} <-
           Replay.load(partition, session_id, cursor: cursor, limit: limit) do
      acc = [events | acc]
      remaining = remaining - length(events)

      cond do
        is_nil(next_cursor) -> {:ok, acc |> Enum.reverse() |> List.flatten(), false}
        remaining == 0 -> {:ok, acc |> Enum.reverse() |> List.flatten(), true}
        true -> load_pages(partition, session_id, next_cursor, acc, remaining)
      end
    end
  end

  defp filtered_events(%Phoenix.LiveView.Socket{} = socket), do: filtered_events(socket.assigns)

  defp filtered_events(assigns),
    do: Enum.filter(assigns.events, &MapSet.member?(assigns.active_kinds, &1.kind))

  defp selected_event(assigns),
    do: Enum.find(assigns.events, &(&1.event_id == assigns.selected_event_id))

  defp selected_position(assigns) do
    assigns
    |> filtered_events()
    |> selected_index(assigns.selected_event_id)
    |> case do
      -1 -> 0
      index -> index + 1
    end
  end

  defp selected_index(%Phoenix.LiveView.Socket{} = socket, events),
    do: selected_index(events, socket.assigns.selected_event_id)

  defp selected_index(events, event_id),
    do: Enum.find_index(events, &(&1.event_id == event_id)) || -1

  defp select_index(socket, index) do
    events = filtered_events(socket)

    case Enum.at(events, max(index, 0)) do
      nil ->
        socket

      event ->
        assign(socket, selected_event_id: event.event_id, selected_source: nil, source_error: nil)
    end
  end

  defp move(socket, delta) do
    events = filtered_events(socket)
    index = selected_index(socket, events)
    select_index(socket, min(max(index + delta, 0), length(events) - 1))
  end

  defp preserve_or_select_first(socket) do
    events = filtered_events(socket)

    if Enum.any?(events, &(&1.event_id == socket.assigns.selected_event_id)) do
      socket
    else
      assign(socket, selected_event_id: events |> List.first() |> event_id())
    end
  end

  defp toggle_from_keyboard(socket) do
    if playable?(socket) do
      playing? = not socket.assigns.playing?
      socket = invalidate_timer(socket, playing?)
      if playing?, do: schedule_tick(socket), else: socket
    else
      socket
    end
  end

  defp playable?(socket), do: filtered_events(socket) != []

  defp invalidate_timer(socket, playing?) do
    assign(socket,
      playing?: playing?,
      playback_generation: socket.assigns.playback_generation + 1
    )
  end

  defp schedule_tick(socket) do
    interval = round(@base_interval_ms / socket.assigns.speed)
    Process.send_after(self(), {:replay_tick, socket.assigns.playback_generation}, interval)
    socket
  end

  defp valid_selected_source(nil, _events), do: nil

  defp valid_selected_source(source, events) do
    with %{links: links} <- Enum.find(events, &(&1.event_id == source.event_id)),
         ids when is_list(ids) <- Map.get(links, String.to_existing_atom(source.kind)),
         true <- source.id in Enum.map(ids, &to_string/1),
         do: source,
         else: (_ -> nil)
  end

  defp event_id(nil), do: nil
  defp event_id(event), do: event.event_id

  defp parse_position(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {position, ""} -> position
      _ -> 1
    end
  end

  defp parse_position(_raw), do: 1

  defp partition_value(nil, _key), do: ""
  defp partition_value(partition, key), do: Map.fetch!(partition, key)

  defp partition_query(partition),
    do: %{
      "host" => partition.host_id,
      "client" => partition.client_id,
      "scope" => partition.scope,
      "namespace" => partition.namespace
    }

  defp replay_state_key(nil, _session_id), do: nil

  defp replay_state_key(partition, session_id) do
    partition
    |> partition_query()
    |> Map.put("session", session_id)
    |> URI.encode_query()
  end

  defp speed_id(speed) when speed == trunc(speed), do: Integer.to_string(trunc(speed))
  defp speed_id(speed), do: :erlang.float_to_binary(speed, decimals: 1)

  defp source_control_id(position, kind, id),
    do: "replay-source-#{position}-#{kind}-#{to_string(id)}"
end
