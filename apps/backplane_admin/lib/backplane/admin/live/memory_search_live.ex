defmodule Backplane.Admin.MemorySearchLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents,
    only: [memory_blank_state: 1, memory_link_button: 1, memory_page_header: 1]

  import Backplane.Admin.MemoryOperatorComponents,
    only: [browse_scope: 1, format_datetime: 1, page: 1, partition_query: 1, source_identity: 1]

  alias Backplane.Memory.Operations.Inventory

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory/search",
       partition: %{},
       page_size: @page_size,
       query: "",
       offset: 0,
       entries: [],
       total: 0,
       next_offset: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    partition = browse_scope(params)
    query = String.trim(params["q"] || "")
    offset = page(params["offset"])
    socket = assign(socket, partition: partition, query: query, offset: offset)

    case Inventory.memories(partition, q: query, limit: @page_size, offset: offset) do
      {:ok, result} ->
        {:noreply, assign(socket, Map.put(result, :error, nil))}

      {:error, reason} ->
        {:noreply, assign(socket, entries: [], total: 0, next_offset: nil, error: reason)}
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => query}}, socket) do
    {:noreply,
     push_patch(socket, to: search_path(socket.assigns.partition, String.trim(query), 0))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-search">
      <.memory_page_header title="Search memories" subtitle="Search stored memory content across sources" />

      <.form for={%{}} as={:search} id="memory-search-form" phx-submit="search" class="memory-toolbar mb-5 flex flex-col gap-3 sm:flex-row sm:items-end">
        <div class="min-w-0 flex-1">
          <.dm_input id="memory-search-query" name="search[q]" type="search" label="Search memories" value={@query} />
        </div>
        <.dm_btn id="memory-search-submit" type="submit" native_submit variant="primary" class="shrink-0">Search</.dm_btn>
      </.form>

      <.dm_alert :if={@error} id="memory-search-error" variant="error" title="Search unavailable">The memory collection could not be searched. Try again.</.dm_alert>
      <p :if={!@error} id="memory-search-count" class="mb-3 text-sm text-on-surface-variant">{@total} matching memories</p>
      <.memory_blank_state :if={!@error && @entries == []} id="memory-search-empty" title={if @query == "", do: "No stored memories yet", else: "No memories match your search"} description={if @query == "", do: "Captured memories will appear here when they are ready. Check Activity for recent capture and processing.", else: "Try a shorter phrase or a different keyword. Search matches the content of stored memories."}>
        <.memory_link_button id="memory-search-activity" navigate={~p"/memory/activity"} variant="ghost" size="sm">View activity</.memory_link_button>
      </.memory_blank_state>

      <ul :if={@entries != []} id="memory-search-results" class="space-y-3">
        <li :for={memory <- @entries} class="memory-record">
          <p class="memory-record-content line-clamp-4">{memory.content}</p>
          <div class="memory-record-meta">
            <.dm_badge variant="secondary" size="sm" soft>{memory.memory_type}</.dm_badge>
            <.source_identity record={memory} />
            <time>{format_datetime(memory.inserted_at)}</time>
            <.link navigate={~p"/memory/memories/#{memory.id}?#{Map.merge(partition_query(@partition), %{"q" => @query, "offset" => @offset})}"} class="ml-auto inline-flex items-center gap-1 font-semibold text-primary underline underline-offset-4">View memory<.dm_mdi name="arrow-top-right" class="h-4 w-4" /></.link>
          </div>
        </li>
      </ul>

      <nav :if={!@error && (@offset > 0 || @next_offset)} aria-label="Search pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="memory-search-previous" patch={search_path(@partition, @query, max(0, @offset - @page_size))}>Previous</.memory_link_button>
        <.memory_link_button :if={@next_offset} id="memory-search-next" patch={search_path(@partition, @query, @next_offset)}>Next</.memory_link_button>
      </nav>
    </div>
    """
  end

  defp search_path(partition, query, offset) do
    ~p"/memory/search?#{Map.merge(partition_query(partition), %{"q" => query, "offset" => offset})}"
  end
end
