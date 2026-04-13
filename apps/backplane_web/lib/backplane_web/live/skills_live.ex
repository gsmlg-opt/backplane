defmodule BackplaneWeb.SkillsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Skills.Registry, as: SkillsRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Backplane.PubSubBroadcaster.subscribe(Backplane.PubSubBroadcaster.skills_sync_topic())
    end

    {:ok, assign(socket, current_path: "/admin/hub/skills", loading: true, search: "", selected: nil)}
  end

  @impl true
  def handle_info({:completed, _payload}, socket) do
    skills = safe_call(fn -> SkillsRegistry.list() end, [])
    {:noreply, assign(socket, skills: skills, filtered_skills: skills)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    skills = safe_call(fn -> SkillsRegistry.list() end, [])
    {:noreply, assign(socket, loading: false, skills: skills, filtered_skills: skills)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered =
      if query == "" do
        socket.assigns.skills
      else
        q = String.downcase(query)

        Enum.filter(socket.assigns.skills, fn skill ->
          String.contains?(String.downcase(skill.name), q) or
            String.contains?(String.downcase(skill.description || ""), q) or
            Enum.any?(skill.tags || [], &String.contains?(String.downcase(&1), q))
        end)
      end

    {:noreply, assign(socket, search: query, filtered_skills: filtered)}
  end

  def handle_event("select", %{"id" => id}, socket) do
    skill = Enum.find(socket.assigns.skills, &(&1.id == id))
    {:noreply, assign(socket, selected: skill)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, selected: nil)}
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex gap-2 mb-6">
        <.dm_btn
          variant={if @current_path in ["/admin/hub", "/admin/hub/upstreams"], do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/upstreams")}
        >
          Upstreams
        </.dm_btn>
        <.dm_btn
          variant={if @current_path == "/admin/hub/skills", do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/skills")}
        >
          Skills
        </.dm_btn>
        <.dm_btn
          variant={if @current_path == "/admin/hub/tools", do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/tools")}
        >
          Tools
        </.dm_btn>
      </div>

      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Skills</h1>
        <span class="text-sm text-on-surface-variant">{length(@filtered_skills)} skills</span>
      </div>

      <div class="mb-4">
        <.dm_input
          id="skills-search"
          type="search"
          name="query"
          value={@search}
          placeholder="Search skills..."
          phx-keyup="search"
          phx-debounce="200"
        />
      </div>

      <div class="space-y-2">
        <.dm_card
          :for={skill <- @filtered_skills}
          variant="bordered"
          class="cursor-pointer"
          phx-click="select"
          phx-value-id={skill.id}
        >
          <:title>
            <span class="text-sm font-medium">{skill.name}</span>
          </:title>
          <p class="text-xs text-on-surface-variant mt-1 line-clamp-1">{skill.description}</p>
          <div :if={skill.tags != []} class="mt-2 flex flex-wrap gap-1">
            <.dm_badge
              :for={tag <- skill.tags || []}
              variant="neutral"
              size="sm"
            >
              {tag}
            </.dm_badge>
          </div>
        </.dm_card>
      </div>

      <div
        :if={@selected}
        class="fixed inset-y-0 right-0 w-[480px] bg-surface-container border-l border-outline-variant p-6 overflow-y-auto z-50"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-bold">{@selected.name}</h2>
          <.dm_btn variant="ghost" size="xs" phx-click="close_detail">X</.dm_btn>
        </div>
        <p class="text-sm text-on-surface-variant mb-4">{@selected.description}</p>
        <div class="prose prose-invert prose-sm max-w-none">
          <pre class="text-xs bg-surface-container-high rounded p-4 overflow-x-auto whitespace-pre-wrap">{@selected.content}</pre>
        </div>
      </div>
    </div>
    """
  end

end
