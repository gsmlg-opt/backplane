defmodule Backplane.Api.Router do
  use Backplane.Api, :router

  forward("/mcp", Backplane.Transport.McpPlug)
  forward("/health", Backplane.Transport.HealthPlug)
  forward("/metrics", Backplane.Transport.MetricsPlug)

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Backplane.Api.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :skills_api do
    plug(:accepts, ["json", "gz"])
  end

  scope "/", Backplane.Api do
    pipe_through(:public_browser)

    get("/", PageController, :home)
  end

  scope "/" do
    pipe_through(:api)

    forward("/llm", Backplane.LLM.ApiRouter)
  end

  scope "/" do
    pipe_through(:skills_api)

    forward("/host-agent", Backplane.Skills.HostAgentApiRouter)
    forward("/skills", Backplane.Skills.ApiRouter)
  end

  match(:*, "/*path", Backplane.Api.NotFoundPlug, [])
end
