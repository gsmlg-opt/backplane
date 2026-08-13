defmodule Backplane.Admin.MemoryProfileLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.MemoryComponents, only: [memory_page_header: 1]
  import Backplane.Admin.MemoryOperatorComponents

  alias Backplane.Memory.Profiles

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         current_path: "/memory/profile",
         partition: nil,
         project: nil,
         profile: nil,
         error: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    with {:ok, partition} <- exact_partition(params),
         project when is_binary(project) <- nonblank(params["project"]) do
      {:noreply,
       assign(socket,
         partition: partition,
         project: project,
         profile: Profiles.get(project, partition),
         error: nil
       )}
    else
      _ -> {:noreply, assign(socket, partition: nil, project: nil, profile: nil, error: nil)}
    end
  rescue
    error -> {:noreply, assign(socket, error: error)}
  end

  @impl true
  def handle_event("select_partition", %{"partition" => raw}, socket),
    do:
      {:noreply, push_patch(socket, to: ~p"/memory/profile?#{selection_query(raw, ["project"])}")}

  @impl true
  def render(%{partition: nil} = assigns) do
    ~H"""
    <.partition_gate id="profile-partition" title="Profile" subtitle="Project intelligence for one exact partition" path="/memory/profile" extra={[{"project", "Project"}]} />
    """
  end

  def render(assigns) do
    ~H"""
    <div id="memory-profile">
      <.memory_page_header title="Profile" subtitle="Project intelligence for one exact partition" />
      <.dm_alert :if={@error} id="profile-error" variant="error" title="Profile unavailable">The profile could not be loaded.</.dm_alert>
      <.dm_alert :if={is_nil(@profile) and !@error} id="profile-pending" variant="info" title="Profile pending">No completed profile exists yet. Profile construction is performed by the background pipeline.</.dm_alert>
      <.dm_card :if={@profile} id="profile-complete" variant="bordered" padding="sm"><div class="flex justify-between"><h2 class="text-lg font-semibold">{@project}</h2><.dm_badge variant="success">Complete</.dm_badge></div><p id="profile-summary" class="mt-2">{@profile.summary}</p><p id="profile-revision" class="text-sm text-on-surface-variant">Revision: {DateTime.to_iso8601(@profile.updated_at)}</p><dl class="mt-4 grid grid-cols-2 gap-3"><div><dt class="text-sm text-on-surface-variant">Sessions</dt><dd class="text-xl font-semibold">{@profile.session_count}</dd></div><div><dt class="text-sm text-on-surface-variant">Observations</dt><dd class="text-xl font-semibold">{@profile.total_observations}</dd></div></dl><section class="mt-4"><h3 class="font-semibold">Top concepts</h3><pre class="mt-2 overflow-auto rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.top_concepts, pretty: true)}</pre></section><section id="profile-linked-sources" class="mt-4"><h3 class="font-semibold">Linked source records</h3><pre class="mt-2 overflow-auto rounded-lg bg-surface-container-high p-3 text-sm">{Jason.encode!(@profile.source_records, pretty: true)}</pre></section><div class="mt-4 grid gap-3 lg:grid-cols-3"><section id="profile-active-lessons"><h3 class="font-semibold">Active lessons</h3><pre>{Jason.encode!(@profile.active_lessons, pretty: true)}</pre></section><section id="profile-recent-crystals"><h3 class="font-semibold">Recent crystals</h3><pre>{Jason.encode!(@profile.recent_crystals, pretty: true)}</pre></section><section id="profile-recent-summaries"><h3 class="font-semibold">Recent summaries</h3><pre>{Jason.encode!(@profile.recent_summaries, pretty: true)}</pre></section></div></.dm_card>
      <div class="mt-5 flex gap-3 text-sm"><.link navigate={~p"/memory/graph?#{partition_query(@partition)}"} class="text-primary underline">Graph</.link><.link navigate={~p"/memory/audit?#{partition_query(@partition)}"} class="text-primary underline">Audit</.link><.link navigate={~p"/memory/config"} class="text-primary underline">Config</.link></div>
    </div>
    """
  end

  defp nonblank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  defp nonblank(_), do: nil
end
