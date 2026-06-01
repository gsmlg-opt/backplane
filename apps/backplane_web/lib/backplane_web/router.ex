defmodule BackplaneWeb.Router do
  use BackplaneWeb, :router

  # MCP transport — forwarded to Plug handler, no Phoenix pipeline
  forward("/api/mcp", Backplane.Transport.McpPlug)
  forward("/health", Backplane.Transport.HealthPlug)
  forward("/metrics", Backplane.Transport.MetricsPlug)

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BackplaneWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Backplane.Web.AdminAuthPlug)
  end

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BackplaneWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :skills_api do
    plug(:accepts, ["json", "gz"])
  end

  scope "/", BackplaneWeb do
    pipe_through(:public_browser)

    get("/", PageController, :home)
  end

  scope "/api" do
    pipe_through(:browser)
    forward("/llm", Backplane.LLM.ApiRouter)
  end

  scope "/api" do
    pipe_through(:skills_api)
    forward("/host-agent", Backplane.Skills.HostAgentApiRouter)
  end

  scope "/api" do
    pipe_through(:skills_api)
    forward("/skills", Backplane.Skills.ApiRouter)
  end

  scope "/admin", BackplaneWeb do
    pipe_through(:browser)

    # Dashboard
    get("/", PageController, :admin)
    live("/dashboard/overview", DashboardLive, :overview)
    live("/dashboard/usage/llm", DashboardUsageLive, :llm)
    live("/dashboard/usage/mcp", DashboardUsageLive, :mcp)

    # Llama
    live("/llama/providers", ProvidersLive, :index)
    live("/llama/providers/new", ProviderNewLive, :new)
    live("/llama/providers/:id", ProviderShowLive, :show)
    live("/llama/model-aliases", SettingsLive, :model_aliases)

    # MCP
    live("/mcp/upstreams", UpstreamsLive, :index)
    live("/mcp/upstreams/new", UpstreamsLive, :new)
    live("/mcp/upstreams/:id/edit", UpstreamsLive, :edit)
    live("/mcp/managed", ManagedLive, :index)
    live("/mcp/managed/:prefix", ManagedServiceSettingsLive, :show)
    live("/mcp/managed/:prefix/tool/:tool_name", ManagedToolDetailLive, :show)
    live("/mcp/agent", AgentMcpLive, :index)
    live("/mcp/agent/new", AgentMcpLive, :new)
    live("/mcp/agent/:id/edit", AgentMcpLive, :edit)
    live("/mcp/inspector", McpInspectorLive, :index)
    live("/mcp/inspector/internal", McpInspectorLive, :internal)

    # Memory
    live("/memory", MemoryOverviewLive, :index)
    live("/memory/observations", MemoryObservationsLive, :index)
    live("/memory/sessions", MemorySessionsLive, :index)
    live("/memory/graph", MemoryGraphLive, :index)
    live("/memory/actions", MemoryActionsLive, :index)
    live("/memory/audit", MemoryAuditLive, :index)
    live("/memory/config", MemoryConfigLive, :index)
    live("/memory/browse", MemoryLive, :index)
    live("/memory/stats", MemoryStatsLive, :index)

    # Skills
    live("/skills", SkillOverviewLive, :index)
    live("/skills/browse", SkillBrowseLive, :index)
    live("/skills/browse/:id", SkillBrowseLive, :show)
    live("/skills/metadata", SkillMetadataLive, :index)
    live("/skills/upstream", SkillUpstreamLive, :index)
    live("/skills/upstream/new", SkillUpstreamLive, :new)
    live("/skills/upstream/:id", SkillUpstreamLive, :show)
    live("/skills/upstream/:id/edit", SkillUpstreamLive, :edit)
    live("/skills/draft", SkillDraftLive, :index)
    live("/skills/draft/new", SkillDraftLive, :new)
    live("/skills/draft/:id/edit", SkillDraftLive, :edit)
    live("/skills/upload", SkillUploadLive, :index)
    live("/skills/upload/:id", SkillUploadLive, :show)

    # System
    live("/system/clients", ClientsLive, :index)
    live("/system/logs", LogsLive, :index)
    live("/system/monitor/plans", MonitorPlansLive, :index)
    live("/system/credentials", SettingsLive, :credentials)
    live("/system/credentials/new", SettingsLive, :credentials_new)
    live("/system/credentials/new/:vendor", SettingsLive, :credentials_new_oauth)
    live("/system/credentials/:name/edit", SettingsLive, :credentials_edit)
    live("/system/host-agents", HostAgentsLive, :index)
    live("/system/host-agents/:id", HostAgentsLive, :show)

    # Dashboard → Plan Usage
    live("/dashboard/usage/plans", DashboardPlanUsageLive, :index)

    # OAuth callbacks
    get("/oauth/callback", OAuthCallbackController, :callback)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:backplane_web, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: Backplane.Telemetry)
    end
  end
end
