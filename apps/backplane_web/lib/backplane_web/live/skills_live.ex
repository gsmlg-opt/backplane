defmodule BackplaneWeb.SkillsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Skills.Registry, as: SkillsRegistry

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Backplane.PubSubBroadcaster.subscribe(Backplane.PubSubBroadcaster.skills_sync_topic())
    end

    {:ok, assign(socket, current_path: "/admin/skills", loading: true, search: "", selected: nil)}
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
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-white">Skills</h1>
        <span class="text-sm text-gray-400">{length(@filtered_skills)} skills</span>
      </div>

      <div class="mb-4">
        <input
          type="text"
          placeholder="Search skills..."
          value={@search}
          phx-keyup="search"
          phx-value-query=""
          class="w-full rounded-lg bg-gray-900 border border-gray-700 px-4 py-2 text-sm text-white placeholder-gray-500 focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500"
          name="query"
          phx-debounce="200"
        />
      </div>

      <div class="space-y-2">
        <div
          :for={skill <- @filtered_skills}
          class="bg-gray-900 border border-gray-800 hover:border-gray-700 rounded-lg p-3 cursor-pointer"
          phx-click="select"
          phx-value-id={skill.id}
        >
          <div class="flex items-center justify-between">
            <span class="text-sm font-medium text-white">{skill.name}</span>
            <span class={[
              "text-xs px-2 py-0.5 rounded",
              source_color(skill.source)
            ]}>
              {skill.source}
            </span>
          </div>
          <p class="text-xs text-gray-400 mt-1 line-clamp-1">{skill.description}</p>
          <div :if={skill.tags != []} class="mt-2 flex flex-wrap gap-1">
            <span
              :for={tag <- skill.tags || []}
              class="text-xs bg-gray-800 text-gray-300 px-1.5 py-0.5 rounded"
            >
              {tag}
            </span>
          </div>
        </div>
      </div>

      <div
        :if={@selected}
        class="fixed inset-y-0 right-0 w-[480px] bg-gray-900 border-l border-gray-800 p-6 overflow-y-auto z-50"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-bold text-white">{@selected.name}</h2>
          <button phx-click="close_detail" class="text-gray-400 hover:text-white">X</button>
        </div>
        <p class="text-sm text-gray-400 mb-4">{@selected.description}</p>
        <div class="prose prose-invert prose-sm max-w-none">
          <pre class="text-xs bg-gray-950 rounded p-4 overflow-x-auto whitespace-pre-wrap">{@selected.content}</pre>
        </div>
      </div>
    </div>
    """
  end

  defp source_color(source) when is_binary(source) do
    cond do
      String.starts_with?(source, "git") -> "bg-blue-900/50 text-blue-300"
      String.starts_with?(source, "local") -> "bg-green-900/50 text-green-300"
      source == "db" -> "bg-purple-900/50 text-purple-300"
      true -> "bg-gray-800 text-gray-300"
    end
  end

  defp source_color(_), do: "bg-gray-800 text-gray-300"
end
