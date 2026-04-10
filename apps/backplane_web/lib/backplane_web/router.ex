defmodule BackplaneWeb.Router do
  use BackplaneWeb, :router

  # MCP transport — forwarded to Plug handler, no Phoenix pipeline
  forward("/mcp", Backplane.Transport.McpPlug)
  forward("/health", Backplane.Transport.HealthPlug)
  forward("/metrics", Backplane.Transport.MetricsPlug)
  # forward("/llm", Backplane.LLM.Router)

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BackplaneWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Backplane.Web.AdminAuthPlug)
  end

  scope "/api" do
    pipe_through(:browser)
    forward("/llm", Backplane.LLM.ApiRouter)
  end

  scope "/admin", BackplaneWeb do
    pipe_through(:browser)

    # Dashboard
    live("/", DashboardLive, :index)

    # MCP Hub
    live("/hub", UpstreamsLive, :index)
    live("/hub/upstreams", UpstreamsLive, :index)
    live("/hub/skills", SkillsLive, :index)
    live("/hub/tools", ToolsLive, :index)

    # LLM Providers
    live("/providers", ProvidersLive, :index)

    # Clients
    live("/clients", ClientsLive, :index)

    # Logs
    live("/logs", LogsLive, :index)

    # Settings
    live("/settings", SettingsLive, :index)
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
