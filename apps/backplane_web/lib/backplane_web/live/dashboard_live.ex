defmodule BackplaneWeb.DashboardLive do
  use BackplaneWeb, :live_view

  alias Backplane.Metrics
  alias Backplane.Proxy.{Pool, Upstreams}
  alias Backplane.PubSubBroadcaster
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Settings.Credentials
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh, @refresh_interval)
      Phoenix.PubSub.subscribe(Backplane.PubSub, Upstreams.topic())
      PubSubBroadcaster.subscribe(PubSubBroadcaster.skills_sync_topic())
      PubSubBroadcaster.subscribe(PubSubBroadcaster.config_reloaded_topic())
    end

    {:ok, assign(socket, current_path: "/admin/dashboard/overview", loading: true)}
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

  def handle_info({:upstream_config, _event, _upstream}, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
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

  defp load_dashboard_data(socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])
    skills = safe_call(fn -> SkillsRegistry.list() end, [])
    upstreams = safe_call(fn -> Pool.list_upstreams() end, [])
    metrics = safe_call(fn -> Metrics.snapshot() end, %{})

    native_tools = Enum.filter(tools, &(&1.origin == :native))
    upstream_tools = Enum.reject(tools, &(&1.origin == :native))

    plan_credentials = safe_call(&load_plan_credentials/0, [])

    assign(socket,
      loading: false,
      tool_count: length(tools),
      native_tool_count: length(native_tools),
      upstream_tool_count: length(upstream_tools),
      skill_count: length(skills),
      upstream_count: length(upstreams),
      upstreams: upstreams,
      metrics: metrics,
      plan_credentials: plan_credentials
    )
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  defp load_plan_credentials do
    Credentials.list()
    |> Enum.filter(fn cred ->
      (cred.metadata || %{})["auth_type"] in [
        "anthropic_oauth",
        "openai_oauth",
        "google_oauth",
        "xai_oauth"
      ]
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Dashboard</h1>
        <div class="flex gap-2">
          <.dm_btn variant="warning" size="sm" phx-click="reconnect_degraded">
            Reconnect Degraded
          </.dm_btn>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 mb-8">
        <.dm_stat title="Total Tools" value={to_string(@tool_count)} />
        <.dm_stat title="Native Tools" value={to_string(@native_tool_count)} />
        <.dm_stat title="Upstream Tools" value={to_string(@upstream_tool_count)} />
        <.dm_stat title="Skills" value={to_string(@skill_count)} />
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 mb-8">
        <.dm_stat title="Upstreams" value={to_string(@upstream_count)} />
        <.dm_stat
          title="Total Requests"
          value={to_string(get_in(@metrics, [:requests, :total]) || 0)}
        />
      </div>

      <div :if={@plan_credentials != []} class="mt-8">
        <h2 class="text-lg font-semibold mb-4">AI Plan Usage</h2>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.dm_card :for={cred <- @plan_credentials} variant="bordered">
            <:title>
              <div class="flex items-center justify-between">
                <span>{plan_label((cred.metadata || %{})["auth_type"])}</span>
                <.dm_badge variant="success">Active</.dm_badge>
              </div>
            </:title>
            <div class="text-sm space-y-1">
              <p class="text-on-surface-variant">
                Credential: <span class="text-on-surface font-mono">{cred.name}</span>
              </p>
              <%= case (cred.metadata || %{})["auth_type"] do %>
                <% "anthropic_oauth" -> %>
                  <p :if={(cred.metadata || %{})["subscription_type"]} class="text-on-surface-variant">
                    Plan:
                    <span class="text-on-surface font-medium">
                      {(cred.metadata || %{})["subscription_type"]}
                    </span>
                  </p>
                  <p :if={(cred.metadata || %{})["organization_uuid"]} class="text-on-surface-variant">
                    Org:
                    <span class="text-on-surface font-mono text-xs">
                      {(cred.metadata || %{})["organization_uuid"]}
                    </span>
                  </p>
                <% "openai_oauth" -> %>
                  <p :if={(cred.metadata || %{})["account_id"]} class="text-on-surface-variant">
                    Account:
                    <span class="text-on-surface font-mono text-xs">
                      {(cred.metadata || %{})["account_id"]}
                    </span>
                  </p>
                <% "google_oauth" -> %>
                  <p :if={(cred.metadata || %{})["client_id"]} class="text-on-surface-variant">
                    Client ID:
                    <span class="text-on-surface font-mono text-xs">
                      {(cred.metadata || %{})["client_id"]}
                    </span>
                  </p>
                <% _ -> %>
              <% end %>
              <p class="text-xs text-on-surface-variant mt-2">
                Updated <.local_time datetime={cred.updated_at} />
              </p>
            </div>
          </.dm_card>
        </div>
      </div>

      <div class="mt-8">
        <h2 class="text-lg font-semibold mb-4">Upstream Status</h2>
        <div :if={@upstreams == []} class="text-on-surface-variant text-sm">
          No upstream MCP servers configured.
        </div>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.dm_card :for={upstream <- @upstreams} variant="bordered">
            <:title>
              <div class="flex items-center justify-between">
                <span>{upstream.name}</span>
                <.dm_badge variant={upstream_badge_color(upstream)}>
                  {upstream_status(upstream) |> to_string() |> String.capitalize()}
                </.dm_badge>
              </div>
            </:title>
            <div class="text-sm text-on-surface-variant">
              <p>Prefix: <span class="text-on-surface">{upstream.prefix}::</span></p>
              <p>Transport: <span class="text-on-surface">{upstream.transport}</span></p>
              <p>Tools: <span class="text-on-surface">{upstream.tool_count || 0}</span></p>
            </div>
          </.dm_card>
        </div>
      </div>
    </div>
    """
  end

  defp plan_label("anthropic_oauth"), do: "Claude Plan"
  defp plan_label("openai_oauth"), do: "OpenAI Codex"
  defp plan_label("google_oauth"), do: "Google Antigravity"
  defp plan_label("xai_oauth"), do: "xAI Grok"
  defp plan_label(other), do: other

  defp upstream_status(%{status: :connected}), do: :connected
  defp upstream_status(%{status: :degraded}), do: :degraded
  defp upstream_status(%{connected: true}), do: :connected
  defp upstream_status(_), do: :disconnected

  defp upstream_badge_color(upstream) do
    case upstream_status(upstream) do
      :connected -> "success"
      :degraded -> "warning"
      :disconnected -> "error"
    end
  end
end
