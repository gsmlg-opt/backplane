defmodule BackplaneWeb.ToolsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Registry.ToolRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/admin/tools", loading: true, search: "", selected: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])
    {:noreply, assign(socket, loading: false, tools: tools, filtered_tools: tools)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered =
      if query == "" do
        socket.assigns.tools
      else
        q = String.downcase(query)

        Enum.filter(socket.assigns.tools, fn tool ->
          String.contains?(String.downcase(tool.name), q) or
            String.contains?(String.downcase(tool.description || ""), q)
        end)
      end

    {:noreply, assign(socket, search: query, filtered_tools: filtered)}
  end

  def handle_event("select", %{"name" => name}, socket) do
    tool = Enum.find(socket.assigns.tools, &(&1.name == name))
    {:noreply, assign(socket, selected: tool)}
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
        <h1 class="text-2xl font-bold text-white">Tools</h1>
        <span class="text-sm text-gray-400">{length(@filtered_tools)} tools</span>
      </div>

      <div class="mb-4">
        <input
          type="text"
          placeholder="Search tools..."
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
          :for={tool <- @filtered_tools}
          class={[
            "bg-gray-900 border rounded-lg p-3 cursor-pointer transition-colors",
            if(@selected && @selected.name == tool.name,
              do: "border-emerald-600",
              else: "border-gray-800 hover:border-gray-700"
            )
          ]}
          phx-click="select"
          phx-value-name={tool.name}
        >
          <div class="flex items-center justify-between">
            <span class="text-sm font-mono text-emerald-400">{tool.name}</span>
            <span class={[
              "text-xs px-2 py-0.5 rounded",
              if(tool.origin == :native,
                do: "bg-blue-900/50 text-blue-300",
                else: "bg-purple-900/50 text-purple-300"
              )
            ]}>
              {origin_label(tool.origin)}
            </span>
          </div>
          <p class="text-xs text-gray-400 mt-1 line-clamp-1">{tool.description}</p>
        </div>
      </div>

      <div
        :if={@selected}
        class="fixed inset-y-0 right-0 w-96 bg-gray-900 border-l border-gray-800 p-6 overflow-y-auto z-50"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-bold text-white">Tool Detail</h2>
          <button
            phx-click="close_detail"
            class="text-gray-400 hover:text-white"
          >
            X
          </button>
        </div>
        <div class="space-y-4">
          <div>
            <dt class="text-xs text-gray-400">Name</dt>
            <dd class="text-sm font-mono text-emerald-400">{@selected.name}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-400">Description</dt>
            <dd class="text-sm text-gray-300">{@selected.description}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-400">Origin</dt>
            <dd class="text-sm text-gray-300">{origin_label(@selected.origin)}</dd>
          </div>
          <div>
            <dt class="text-xs text-gray-400">Input Schema</dt>
            <dd class="text-xs font-mono text-gray-300 bg-gray-950 rounded p-3 overflow-x-auto">
              <pre>{Jason.encode!(@selected.input_schema || %{}, pretty: true)}</pre>
            </dd>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp origin_label(:native), do: "native"
  defp origin_label({:upstream, name}), do: "upstream:#{name}"
  defp origin_label(other), do: to_string(other)
end
