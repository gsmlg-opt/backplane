defmodule BackplaneWeb.Router do
  use BackplaneWeb, :router

  # MCP transport — forwarded to Plug handler, no Phoenix pipeline
  forward "/mcp", Backplane.Transport.McpPlug
  forward "/webhook", Backplane.Transport.WebhookPlug
  forward "/health", Backplane.Transport.HealthPlug
  forward "/metrics", Backplane.Transport.MetricsPlug

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BackplaneWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Backplane.Web.AdminAuthPlug
  end

  scope "/admin", BackplaneWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/upstreams", UpstreamsLive, :index)
    live("/skills", SkillsLive, :index)
    live("/docs", DocsLive, :index)
    live("/tools", ToolsLive, :index)
    live("/git", GitProvidersLive, :index)
    live("/logs", LogsLive, :index)
    live("/projects", ProjectsLive, :index)
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:backplane, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)
      live_dashboard("/dashboard", metrics: Backplane.Telemetry)
    end
  end
end
