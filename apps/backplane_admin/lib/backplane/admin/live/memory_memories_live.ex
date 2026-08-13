defmodule Backplane.Admin.MemoryMemoriesLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_link_button: 1, memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Memories

  @page_size 25

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/memories",
         page_size: @page_size,
         partition: nil,
         rows: [],
         selected: nil,
         offset: 0,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    case exact_partition(params) do
      {:ok, partition} -> load(socket, partition, params)
      _ -> {:noreply, assign(socket, partition: nil, rows: [], selected: nil, error: nil)}
    end
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do: {:noreply, push_patch(socket, to: ~p"/memory/memories?#{selection_query(raw)}")}

  @impl true
  def render(%{partition: nil} = assigns) do
    ~H"""
    <.partition_gate id="memories-partition" title="Memories" subtitle="Durable memory inventory, evidence, and provenance" path="/memory/memories" />
    """
  end

  def render(assigns) do
    ~H"""
    <div id="memory-memories">
      <.memory_page_header title="Memories" subtitle="Durable memory inventory, evidence, and provenance" />
      <.dm_alert :if={@error} id="memories-error" variant="error" title="Memories unavailable">The bounded partition query failed.</.dm_alert>
      <.dm_card :if={@rows == [] and !@error} id="memories-empty" variant="bordered" padding="lg"><h2 class="text-lg font-semibold">No memories in this partition</h2></.dm_card>
      <div class="overflow-x-auto">
        <.dm_table :if={@rows != []} id="memory-memories-table" data={@rows} compact hover zebra>
          <:col :let={memory} label="Memory"><.link navigate={detail_path(memory.id, @partition, @offset)} class="text-primary underline">{memory.content}</.link></:col>
          <:col :let={memory} label="Type">{memory.memory_type}</:col>
          <:col :let={memory} label="State"><.dm_badge variant={status_variant(memory.lifecycle_state)} size="sm">{memory.lifecycle_state}</.dm_badge></:col>
          <:col :let={memory} label="Applications">{memory.application_count}</:col>
          <:col :let={memory} label="Created">{format_datetime(memory.inserted_at)}</:col>
        </.dm_table>
      </div>
      <nav aria-label="Memory pagination" class="mt-4 flex justify-end gap-2">
        <.memory_link_button :if={@offset > 0} id="memories-previous" patch={page_path(@partition, max(0, @offset - @page_size))}>Previous</.memory_link_button>
        <.memory_link_button :if={length(@rows) == @page_size} id="memories-next" patch={page_path(@partition, @offset + @page_size)}>Next</.memory_link_button>
      </nav>
      <aside :if={@selected} id="memory-detail" class="mt-6">
        <.dm_card variant="bordered" padding="sm">
          <h2 class="text-lg font-semibold">Memory detail</h2>
          <p class="mt-3 whitespace-pre-wrap">{@selected.memory.content}</p>
          <div class="mt-4 flex flex-wrap gap-3 text-sm">
            <.link navigate={~p"/memory/sessions?#{session_query(@selected.memory, @partition)}"} class="text-primary underline">Session</.link>
            <.link navigate={~p"/memory/replay?#{session_query(@selected.memory, @partition)}"} class="text-primary underline">Replay</.link>
            <.link navigate={~p"/memory/audit?#{Map.merge(partition_query(@partition), %{"target" => @selected.memory.id})}"} class="text-primary underline">Audit</.link>
          </div>
          <section id="memory-evidence" class="mt-5"><h3 class="font-semibold">Evidence</h3><p :if={@selected.evidence == []} class="mt-2 text-sm text-on-surface-variant">No durable evidence</p><ul class="mt-2 space-y-2"><li :for={evidence <- @selected.evidence}>
            <.link :if={evidence_path(evidence, @partition)} navigate={evidence_path(evidence, @partition)} class="text-primary underline">{evidence_label(evidence)}</.link>
            <span :if={!evidence_path(evidence, @partition)}>{evidence.evidence_kind}</span>
            · {evidence.excerpt || "No excerpt"}
          </li></ul></section>
        </.dm_card>
      </aside>
    </div>
    """
  end

  defp load(socket, partition, params) do
    offset = page(params["offset"])
    rows = Memories.list([limit: @page_size, offset: offset], partition)

    selected =
      case {socket.assigns.live_action, params["id"]} do
        {:show, id} ->
          with {:ok, memory} <- Memories.get(id, partition),
               {:ok, verification} <- Memories.verify(id, partition),
               do: %{memory: memory, evidence: verification.evidence}

        _ ->
          nil
      end

    {:noreply,
     assign(socket,
       partition: partition,
       rows: rows,
       selected: selected,
       offset: offset,
       error: nil
     )}
  rescue
    error ->
      {:noreply, assign(socket, partition: partition, rows: [], selected: nil, error: error)}
  end

  defp page_path(partition, offset),
    do: ~p"/memory/memories?#{Map.put(partition_query(partition), "offset", offset)}"

  defp detail_path(id, partition, offset),
    do: ~p"/memory/memories/#{id}?#{Map.put(partition_query(partition), "offset", offset)}"

  defp session_query(memory, partition),
    do: Map.merge(partition_query(partition), %{"session" => memory.session_id || ""})

  defp evidence_path(%{source_type: "event", source_id: id}, _partition) when is_binary(id),
    do: ~p"/memory/events/#{id}"

  defp evidence_path(%{source_type: "summary", session_id: session_id}, partition)
       when is_binary(session_id) and session_id != "",
       do: ~p"/memory/sessions?#{Map.put(partition_query(partition), "session", session_id)}"

  defp evidence_path(%{source_type: "session", source_id: source_id}, partition)
       when is_binary(source_id) do
    case String.split(source_id, ":", parts: 2) do
      [_host, session_id] when session_id != "" ->
        ~p"/memory/sessions?#{Map.put(partition_query(partition), "session", session_id)}"

      _ ->
        nil
    end
  end

  defp evidence_path(%{session_id: session_id}, partition)
       when is_binary(session_id) and session_id != "",
       do: ~p"/memory/replay?#{Map.put(partition_query(partition), "session", session_id)}"

  defp evidence_path(_evidence, _partition), do: nil

  defp evidence_label(%{source_type: "event"}), do: "Event"
  defp evidence_label(%{source_type: "summary"}), do: "Session summary"
  defp evidence_label(%{source_type: "session"}), do: "Session"
  defp evidence_label(_evidence), do: "Replay source"
end
