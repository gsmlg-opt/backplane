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
         selected_profile_id: nil,
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
       selected_profile_id: params["profile"],
       profiles: result.entries,
       total: result.total,
       offset: page(params["offset"]),
       next_offset: result.next_offset,
       error: nil
     )}
  rescue
    error ->
      {:noreply,
       assign(socket,
         partition: browse_scope(params),
         project: params["project"],
         selected_profile_id: params["profile"],
         profile: nil,
         profiles: [],
         total: 0,
         offset: page(params["offset"]),
         next_offset: nil,
         error: error
       )}
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
      <.dm_card :if={@profile} id="profile-complete" variant="bordered" padding="sm" class="mb-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <div class="min-w-0"><h2 class="break-words text-lg font-semibold">{@profile.project}</h2><p id="profile-revision" class="mt-1 text-xs text-on-surface-variant">Updated {DateTime.to_iso8601(@profile.updated_at)}</p></div>
          <.link id="profile-close-detail" patch={~p"/memory/profile?#{Map.put(partition_query(@partition), "offset", @offset)}"} class="btn btn-ghost btn-sm">Back to profiles</.link>
        </div>
        <p id="profile-summary" class="memory-record-content mt-4">{@profile.summary}</p>
        <dl class="mt-4 flex flex-wrap gap-8">
          <div><dt class="text-sm text-on-surface-variant">Sessions</dt><dd class="text-xl font-semibold">{@profile.session_count}</dd></div>
          <div><dt class="text-sm text-on-surface-variant">Observations</dt><dd class="text-xl font-semibold">{@profile.total_observations}</dd></div>
        </dl>
        <section class="mt-5">
          <h3 class="font-semibold">Top concepts</h3>
          <p :if={@profile.top_concepts in [nil, %{}]} class="mt-2 text-sm text-on-surface-variant">No concepts recorded.</p>
          <ul :if={@profile.top_concepts not in [nil, %{}]} class="mt-2 flex flex-wrap gap-2">
            <li :for={{concept, value} <- @profile.top_concepts || %{}} class="min-w-0 max-w-full rounded-lg border border-outline-variant px-3 py-2 text-sm [overflow-wrap:anywhere]"><span>{concept}</span><span class="ml-2 font-mono text-on-surface-variant">{Jason.encode!(value)}</span></li>
          </ul>
        </section>
        <details id="profile-source-details" class="memory-disclosure">
          <summary>Source records and generated sections</summary>
          <div class="memory-disclosure-body space-y-4">
            <section id="profile-linked-sources"><h3 class="font-semibold">Linked source records</h3><pre class="mt-2 rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.source_records, pretty: true)}</pre></section>
            <section id="profile-active-lessons"><h3 class="font-semibold">Active lessons</h3><pre class="mt-2 rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.active_lessons, pretty: true)}</pre></section>
            <section id="profile-recent-crystals"><h3 class="font-semibold">Recent crystals</h3><pre class="mt-2 rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.recent_crystals, pretty: true)}</pre></section>
            <section id="profile-recent-summaries"><h3 class="font-semibold">Recent summaries</h3><pre class="mt-2 rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.recent_summaries, pretty: true)}</pre></section>
          </div>
        </details>
      </.dm_card>
      <p :if={!@error} id="profiles-count" class="mb-3 text-sm">{@total} matching profiles</p>
      <div class="overflow-x-auto">
      <.dm_table :if={@profiles != []} id="memory-profiles-table" data={@profiles} compact hover zebra>
        <:col :let={row} label="Project"><.link patch={~p"/memory/profile?#{Map.merge(partition_query(@partition), %{"profile" => row.id, "offset" => @offset})}"} class="text-primary underline">{row.project}</.link></:col>
        <:col :let={row} label="Source host">{row.host_id || "Unknown"}</:col>
        <:col :let={row} label="Summary">{row.summary}</:col>
      </.dm_table>
      </div>
      <nav :if={!@error} class="mt-3 flex gap-3" aria-label="Profile pagination">
        <.link :if={@offset > 0} patch={~p"/memory/profile?#{Map.put(partition_query(@partition), "offset", max(0, @offset - 25))}"}>Previous</.link>
        <.link :if={@next_offset} patch={~p"/memory/profile?#{Map.put(partition_query(@partition), "offset", @next_offset)}"}>Next</.link>
      </nav>
      <.dm_alert :if={@error} id="profile-error" variant="error" title="Profile unavailable">The profile could not be loaded.</.dm_alert>
      <.dm_alert :if={!@error && @selected_profile_id && is_nil(@profile)} id="profile-missing" variant="warning" title="Profile not found">The selected profile is unavailable for the current sources. Choose another profile from the inventory.</.dm_alert>
      <.dm_alert :if={!@error && !@selected_profile_id && @total == 0} id="profile-pending" variant="info" title="No profiles yet">No completed profiles match the current sources. Profiles are built by the background pipeline.</.dm_alert>
      <.dm_alert :if={!@error && !@selected_profile_id && @total > 0} id="profile-select" variant="info" title="Choose a profile">Select a project from the inventory to inspect its completed profile.</.dm_alert>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/graph?#{partition_query(@partition)}"} class="text-primary underline">Graph</.link><.link navigate={~p"/memory/audit?#{partition_query(@partition)}"} class="text-primary underline">Audit</.link><.link navigate={~p"/memory/config"} class="text-primary underline">Config</.link></div>
    </div>
    """
  end
end
