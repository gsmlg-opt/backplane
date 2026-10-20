defmodule Backplane.Admin.MemoryProfileLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Operations.Inventory

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/profile",
         partition: nil,
         project: nil,
         profile: nil,
         profiles: [],
         total: 0,
         offset: 0,
         next_offset: nil,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    partition = browse_scope(params)
    {:ok, result} = Inventory.profiles(partition, limit: 25, offset: page(params["offset"]))

    profile =
      if params["profile"] do
        {:ok, selected} = Inventory.profiles(partition, id: params["profile"], limit: 1)
        List.first(selected.entries)
      end

    {:noreply,
     assign(socket,
       partition: partition,
       project: params["project"],
       profile: profile,
       profiles: result.entries,
       total: result.total,
       offset: page(params["offset"]),
       next_offset: result.next_offset,
       error: nil
     )}
  rescue
    error -> {:noreply, assign(socket, error: error)}
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/memory/profile?#{selection_query(raw, ["project"])}")}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="memory-profile">
      <.memory_page_header title="Profile" subtitle="Project intelligence across stored sources" />
      <p id="profiles-count" class="mb-3 text-sm">{@total} matching profiles</p>
      <.dm_table :if={@profiles != []} id="memory-profiles-table" data={@profiles} compact hover zebra>
        <:col :let={row} label="Project"><.link patch={~p"/memory/profile?#{Map.put(partition_query(@partition), "profile", row.id)}"} class="text-primary underline">{row.project}</.link></:col>
        <:col :let={row} label="Source host">{row.host_id || "Unknown"}</:col>
        <:col :let={row} label="Summary">{row.summary}</:col>
      </.dm_table>
      <nav class="mt-3 flex gap-3" aria-label="Profile pagination">
        <.link :if={@offset > 0} patch={~p"/memory/profile?#{Map.put(partition_query(@partition), "offset", max(0, @offset - 25))}"}>Previous</.link>
        <.link :if={@next_offset} patch={~p"/memory/profile?#{Map.put(partition_query(@partition), "offset", @next_offset)}"}>Next</.link>
      </nav>
      <.dm_alert :if={@error} id="profile-error" variant="error" title="Profile unavailable">The profile could not be loaded.</.dm_alert>
      <.dm_alert :if={is_nil(@profile) and !@error} id="profile-pending" variant="info" title="Profile pending">No completed profile exists yet. Profile construction is performed by the background pipeline.</.dm_alert>
      <.dm_card :if={@profile} id="profile-complete" variant="bordered" padding="sm"><div class="flex justify-between"><h2 class="text-lg font-semibold">{@profile.project}</h2><.dm_badge variant="success">Complete</.dm_badge></div><p id="profile-summary" class="mt-2">{@profile.summary}</p><p id="profile-revision" class="text-sm text-on-surface-variant">Revision: {DateTime.to_iso8601(@profile.updated_at)}</p><dl class="mt-4 grid grid-cols-2 gap-3"><div><dt class="text-sm text-on-surface-variant">Sessions</dt><dd class="text-xl font-semibold">{@profile.session_count}</dd></div><div><dt class="text-sm text-on-surface-variant">Observations</dt><dd class="text-xl font-semibold">{@profile.total_observations}</dd></div></dl><section class="mt-4"><h3 class="font-semibold">Top concepts</h3><pre class="mt-2 overflow-auto rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.top_concepts, pretty: true)}</pre></section><section id="profile-linked-sources" class="mt-4"><h3 class="font-semibold">Linked source records</h3><pre class="mt-2 overflow-auto rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.source_records, pretty: true)}</pre></section><div class="mt-4 grid gap-3 lg:grid-cols-3"><section id="profile-active-lessons"><h3 class="font-semibold">Active lessons</h3><pre>{Jason.encode!(@profile.active_lessons, pretty: true)}</pre></section><section id="profile-recent-crystals"><h3 class="font-semibold">Recent crystals</h3><pre>{Jason.encode!(@profile.recent_crystals, pretty: true)}</pre></section><section id="profile-recent-summaries"><h3 class="font-semibold">Recent summaries</h3><pre>{Jason.encode!(@profile.recent_summaries, pretty: true)}</pre></section></div></.dm_card>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/graph?#{partition_query(@partition)}"} class="text-primary underline">Graph</.link><.link navigate={~p"/memory/audit?#{partition_query(@partition)}"} class="text-primary underline">Audit</.link><.link navigate={~p"/memory/config"} class="text-primary underline">Config</.link></div>
    </div>
    """
  end
end
