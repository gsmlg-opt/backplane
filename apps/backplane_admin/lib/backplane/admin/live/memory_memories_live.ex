defmodule Backplane.Admin.MemoryMemoriesLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Memories
  alias Backplane.Memory.Operations.Inventory

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/memory/memories",
       page_size: @page_size,
       partition: nil,
       rows: [],
       selected: nil,
       offset: 0,
       error: nil,
       detail_error: nil,
       query_params: %{},
       filters: %{},
       total_count: 0
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    load(socket, browse_scope(params), params)
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/memory/memories?#{selection_query(raw)}")}

  def handle_event("filter", %{"filters" => filters}, socket) do
    query =
      Map.merge(
        partition_query(socket.assigns.partition),
        Map.take(filters, ~w(q type session sort))
      )

    {:noreply, push_patch(socket, to: ~p"/memory/memories?#{query}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-memories">
      <.memory_page_header title="Memories" subtitle="Durable memory inventory, evidence, and provenance" />
      <.form for={%{}} as={:filters} id="memories-filters" phx-submit="filter" class="mb-4 flex flex-wrap items-end gap-3">
        <.dm_input name="filters[q]" label="Search" value={@filters["q"] || ""} />
        <.dm_input name="filters[type]" label="Type" value={@filters["type"] || ""} />
        <.dm_input name="filters[session]" label="Session" value={@filters["session"] || ""} />
        <.dm_select id="memories-sort" name="filters[sort]" label="Sort" value={@filters["sort"] || "newest"} options={[{"newest", "Newest first"}, {"oldest", "Oldest first"}]} />
        <.dm_btn type="submit" variant="primary">Filter</.dm_btn>
      </.form>
      <p :if={!@error} id="memories-count" class="mb-3 text-sm text-on-surface-variant">{@total_count} matching memories</p>
      <.dm_alert :if={@error} id="memories-error" variant="error" title="Memories unavailable">The memory collection could not be loaded.</.dm_alert>
      <.dm_alert :if={@detail_error} id="memory-detail-unavailable" variant="warning" title="Memory unavailable">This memory is missing, deleted, or unavailable for the current filters.</.dm_alert>
      <.dm_card :if={@rows == [] and !@error} id="memories-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No memories match</h2></.dm_card>
      <div class="overflow-x-auto">
        <.dm_table :if={@rows != []} id="memory-memories-table" data={@rows} compact hover zebra>
          <:col :let={memory} label="Memory"><.link navigate={detail_path(memory.id, @partition, @offset, @filters)} class="text-primary underline">{memory.content}</.link></:col>
          <:col :let={memory} label="Source"><.source_identity record={memory} /></:col>
          <:col :let={memory} label="Type">{memory.memory_type}</:col>
          <:col :let={memory} label="State"><.dm_badge variant={status_variant(memory.lifecycle_state)} size="sm">{memory.lifecycle_state}</.dm_badge></:col>
          <:col :let={memory} label="Applications">{memory.application_count}</:col>
          <:col :let={memory} label="Created">{format_datetime(memory.inserted_at)}</:col>
        </.dm_table>
      </div>
      <nav aria-label="Memory pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="memories-previous" patch={page_path(@partition, max(0, @offset - @page_size), @filters)}>Previous</.memory_link_button>
        <.memory_link_button :if={@offset + length(@rows) < @total_count} id="memories-next" patch={page_path(@partition, @offset + @page_size, @filters)}>Next</.memory_link_button>
      </nav>
      <aside :if={@selected} id="memory-detail" class="mt-6">
        <.dm_card variant="bordered" padding="sm">
          <h2 class="text-lg font-semibold">Memory detail</h2>
          <div id="memory-detail-source" class="mt-3"><.source_identity record={@selected.memory} detail /></div>
          <p class="mt-3 whitespace-pre-wrap">{@selected.memory.content}</p>
          <div class="mt-4 flex flex-wrap gap-3 text-sm">
            <.link :if={@selected.memory.session_id not in [nil, ""]} navigate={~p"/memory/sessions/#{@selected.memory.session_id}?#{partition_query(record_partition(@selected.memory, @partition))}"} class="text-primary underline">Session</.link>
            <.link :if={@selected.memory.session_id not in [nil, ""]} navigate={~p"/memory/replay?#{session_query(@selected.memory, record_partition(@selected.memory, @partition))}"} class="text-primary underline">Replay</.link>
            <.link navigate={~p"/memory/audit?#{Map.merge(partition_query(record_partition(@selected.memory, @partition)), %{"target" => @selected.memory.id})}"} class="text-primary underline">Audit</.link>
          </div>
          <section id="memory-evidence" class="mt-5"><h3 class="font-semibold">Evidence</h3><p :if={@selected.evidence == []} class="mt-2 text-sm text-on-surface-variant">No durable evidence</p><ul class="mt-2 space-y-2"><li :for={evidence <- @selected.evidence}>
            <.link :if={evidence_path(evidence, @selected.memory.id, record_partition(@selected.memory, @partition))} navigate={evidence_path(evidence, @selected.memory.id, record_partition(@selected.memory, @partition))} class="text-primary underline">{evidence_label(evidence)}</.link>
            <span :if={!evidence_path(evidence, @selected.memory.id, record_partition(@selected.memory, @partition))}>{evidence.evidence_kind}</span>
            · {evidence.excerpt || "No excerpt"}
          </li></ul></section>
        </.dm_card>
      </aside>
    </div>
    """
  end

  defp load(socket, partition, params) do
    offset = page(params["offset"])
    filters = Map.take(params, ~w(q type session sort))

    opts = [
      q: filters["q"],
      type: filters["type"],
      session_id: filters["session"],
      sort: filters["sort"]
    ]

    {:ok, inventory} = Inventory.memories(partition, opts ++ [limit: @page_size, offset: offset])
    rows = inventory.entries
    total_count = inventory.total

    selected =
      case {socket.assigns.live_action, params["id"]} do
        {:show, id} ->
          with {:ok, _uuid} <- Ecto.UUID.cast(id),
               {:ok, identity} <- Inventory.identity(:memory, id, partition),
               {:ok, memory} <- Memories.get(id, identity),
               {:ok, verification} <- Memories.verify(id, identity),
               do: {:ok, %{memory: memory, evidence: verification.evidence}}

        _ ->
          nil
      end

    {selected, detail_error} =
      case selected do
        {:ok, detail} -> {detail, nil}
        nil -> {nil, nil}
        error -> {nil, error}
      end

    {:noreply,
     assign(socket,
       partition: partition,
       rows: rows,
       selected: selected,
       offset: offset,
       error: nil,
       detail_error: detail_error,
       query_params: params,
       filters: filters,
       total_count: total_count
     )}
  rescue
    error ->
      {:noreply,
       assign(socket,
         partition: partition,
         rows: [],
         selected: nil,
         error: error,
         detail_error: nil,
         query_params: params,
         filters: Map.take(params, ~w(q type session sort))
       )}
  end

  defp page_path(partition, offset, filters),
    do:
      ~p"/memory/memories?#{Map.merge(partition_query(partition), Map.put(filters, "offset", offset))}"

  defp detail_path(id, partition, offset, filters),
    do:
      ~p"/memory/memories/#{id}?#{Map.merge(partition_query(partition), Map.put(filters, "offset", offset))}"

  defp session_query(memory, partition),
    do: Map.merge(partition_query(partition), %{"session" => memory.session_id || ""})

  defp evidence_path(%{source_type: "event", source_id: id}, _memory_id, partition)
       when is_binary(id),
       do: ~p"/memory/events/#{id}?#{partition_query(partition)}"

  defp evidence_path(%{source_type: "summary", session_id: session_id}, _memory_id, partition)
       when is_binary(session_id) and session_id != "",
       do: ~p"/memory/sessions/#{session_id}?#{partition_query(partition)}"

  defp evidence_path(%{source_type: "session", source_id: source_id}, _memory_id, partition)
       when is_binary(source_id) do
    case String.split(source_id, ":", parts: 2) do
      [_host, session_id] when session_id != "" ->
        ~p"/memory/sessions/#{session_id}?#{partition_query(partition)}"

      _ ->
        nil
    end
  end

  defp evidence_path(%{session_id: session_id}, _memory_id, partition)
       when is_binary(session_id) and session_id != "",
       do: ~p"/memory/replay?#{Map.put(partition_query(partition), "session", session_id)}"

  defp evidence_path(_evidence, _memory_id, _partition), do: nil

  defp evidence_label(%{source_type: "event"}), do: "Event"
  defp evidence_label(%{source_type: "summary"}), do: "Session summary"
  defp evidence_label(%{source_type: "session"}), do: "Session"
  defp evidence_label(_evidence), do: "Replay source"
end
