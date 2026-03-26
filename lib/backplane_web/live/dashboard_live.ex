defmodule BackplaneWeb.DashboardLive do
  use BackplaneWeb, :live_view

  alias Backplane.Metrics
  alias Backplane.Proxy.Pool
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
      PubSubBroadcaster.subscribe(PubSubBroadcaster.skills_sync_topic())
      PubSubBroadcaster.subscribe(PubSubBroadcaster.docs_reindex_topic())
      PubSubBroadcaster.subscribe(PubSubBroadcaster.config_reloaded_topic())
    end

    {:ok, assign(socket, current_path: "/admin", loading: true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, load_dashboard_data(socket)}
  end

  def handle_info({event, _payload}, socket)
      when event in [:completed, :reloaded] do
    {:noreply, load_dashboard_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("sync_skills", _, socket) do
    sources = Application.get_env(:backplane, :skill_sources, [])

    for source <- sources do
      case Backplane.Skills.Sync.build_job(source) |> Oban.insert() do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end

    {:noreply,
     socket
     |> put_flash(:info, "Skill sync jobs enqueued")
     |> load_dashboard_data()}
  end

  def handle_event("reconnect_degraded", _, socket) do
    pids = safe_call(fn -> Pool.list_upstream_pids() end, [])

    count =
      Enum.count(pids, fn {pid, status} ->
        if status.status in [:degraded, :disconnected] do
          Backplane.Proxy.Upstream.refresh(pid)
          true
        else
          false
        end
      end)

    {:noreply,
     socket
     |> put_flash(:info, "Reconnect triggered for #{count} degraded/disconnected upstreams")
     |> load_dashboard_data()}
  end

  def handle_event("reindex_all", _, socket) do
    projects = safe_call(fn -> Backplane.Repo.all(Backplane.Docs.Project) end, [])

    for project <- projects do
      case Backplane.Jobs.Reindex.new(%{project_id: project.id}) |> Oban.insert() do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end

    {:noreply,
     socket
     |> put_flash(:info, "Reindex jobs enqueued for #{length(projects)} projects")
     |> load_dashboard_data()}
  end

  defp load_dashboard_data(socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])
    skills = safe_call(fn -> SkillsRegistry.list() end, [])
    upstreams = safe_call(fn -> Pool.list_upstreams() end, [])
    metrics = safe_call(fn -> Metrics.snapshot() end, %{})

    native_tools = Enum.filter(tools, &(&1.origin == :native))
    upstream_tools = Enum.reject(tools, &(&1.origin == :native))

    projects =
      safe_call(
        fn -> Backplane.Repo.all(Backplane.Docs.Project) end,
        []
      )

    chunk_count =
      safe_call(
        fn -> Backplane.Repo.aggregate(Backplane.Docs.DocChunk, :count) end,
        0
      )

    assign(socket,
      loading: false,
      tool_count: length(tools),
      native_tool_count: length(native_tools),
      upstream_tool_count: length(upstream_tools),
      skill_count: length(skills),
      upstream_count: length(upstreams),
      upstreams: upstreams,
      project_count: length(projects),
      chunk_count: chunk_count,
      metrics: metrics
    )
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
        <h1 class="text-2xl font-bold text-white">Dashboard</h1>
        <div class="flex gap-2">
          <button
            phx-click="sync_skills"
            class="rounded-md bg-emerald-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-600"
          >
            Sync Skills
          </button>
          <button
            phx-click="reconnect_degraded"
            class="rounded-md bg-amber-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-600"
          >
            Reconnect Degraded
          </button>
          <button
            phx-click="reindex_all"
            class="rounded-md bg-blue-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-600"
          >
            Reindex All
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 mb-8">
        <.stat_card label="Total Tools" value={to_string(@tool_count)} />
        <.stat_card label="Native Tools" value={to_string(@native_tool_count)} />
        <.stat_card label="Upstream Tools" value={to_string(@upstream_tool_count)} />
        <.stat_card label="Skills" value={to_string(@skill_count)} />
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 mb-8">
        <.stat_card label="Upstreams" value={to_string(@upstream_count)} />
        <.stat_card label="Doc Projects" value={to_string(@project_count)} />
        <.stat_card label="Doc Chunks" value={to_string(@chunk_count)} />
        <.stat_card
          label="Total Requests"
          value={to_string(get_in(@metrics, [:requests, :total]) || 0)}
        />
      </div>

      <div class="mt-8">
        <h2 class="text-lg font-semibold text-white mb-4">Upstream Status</h2>
        <div :if={@upstreams == []} class="text-gray-400 text-sm">
          No upstream MCP servers configured.
        </div>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <div
            :for={upstream <- @upstreams}
            class="bg-gray-900 border border-gray-800 rounded-lg p-4"
          >
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-sm font-medium text-white">{upstream.name}</h3>
              <.status_badge status={upstream_status(upstream)} />
            </div>
            <div class="text-xs text-gray-400">
              <p>Prefix: <span class="text-gray-300">{upstream.prefix}::</span></p>
              <p>Transport: <span class="text-gray-300">{upstream.transport}</span></p>
              <p>Tools: <span class="text-gray-300">{upstream.tool_count || 0}</span></p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp upstream_status(%{status: :connected}), do: :connected
  defp upstream_status(%{status: :degraded}), do: :degraded
  defp upstream_status(%{connected: true}), do: :connected
  defp upstream_status(_), do: :disconnected
end
