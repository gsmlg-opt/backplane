defmodule Backplane.Admin.Router do
  use Backplane.Admin, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Backplane.Admin.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Backplane.Web.AdminAuthPlug)
  end

  scope "/", Backplane.Admin do
    pipe_through(:browser)

    get("/", PageController, :admin)
    live("/dashboard/overview", DashboardLive, :overview)
    live("/dashboard/usage/llm", DashboardUsageLive, :llm)
    live("/dashboard/usage/mcp", DashboardUsageLive, :mcp)
    live("/llama/providers", ProvidersLive, :index)
    live("/llama/providers/new", ProviderNewLive, :new)
    live("/llama/providers/:id", ProviderShowLive, :show)
    live("/llama/embedding", EmbeddingLive, :index)
    live("/llama/model-aliases", SettingsLive, :model_aliases)
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
    live("/memory", MemoryOverviewLive, :index)
    live("/memory/observations", MemoryObservationsLive, :index)
    live("/memory/sessions", MemorySessionsLive, :index)
    live("/memory/graph", MemoryGraphLive, :index)
    live("/memory/actions", MemoryActionsLive, :index)
    live("/memory/audit", MemoryAuditLive, :index)
    live("/memory/config", MemoryConfigLive, :index)
    live("/memory/browse", MemoryLive, :index)
    live("/memory/stats", MemoryStatsLive, :index)
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
    live("/system/clients", ClientsLive, :index)
    live("/system/logs", LogsLive, :index)
    live("/system/monitor/plans", MonitorPlansLive, :index)
    live("/system/monitor/plans/new", MonitorPlansLive, :new)
    live("/system/monitor/plans/:id/edit", MonitorPlansLive, :edit)
    live("/system/credentials", SettingsLive, :credentials)
    live("/system/credentials/new", SettingsLive, :credentials_new)
    live("/system/credentials/new/:vendor", SettingsLive, :credentials_new_oauth)
    live("/system/credentials/:name/edit", SettingsLive, :credentials_edit)
    live("/system/host-agents", HostAgentsLive, :index)
    live("/system/host-agents/:id", HostAgentsLive, :show)
    live("/dashboard/usage/plans", DashboardPlanUsageLive, :index)
    get("/oauth/callback", OAuthCallbackController, :callback)
  end

  if Application.compile_env(:backplane_admin, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: Backplane.Telemetry)
    end
  end

  match(:*, "/*path", Backplane.Admin.PageController, :not_found)
end
