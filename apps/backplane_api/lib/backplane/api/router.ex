defmodule Backplane.Api.Router do
  use Backplane.Api, :router

  forward("/mcp", Backplane.Transport.McpPlug)

  pipeline :public_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Backplane.Api.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :skills_api do
    plug(:accepts, ["json", "gz"])
  end

  pipeline :oauth_api do
    plug(:accepts, ["json"])
  end

  pipeline :memory_api do
    plug(:accepts, ["json"])
    plug(Backplane.Auth.ResourceAuthPlug, resource: :mcp)
  end

  scope "/", Backplane.Api do
    pipe_through(:public_browser)

    get("/", PageController, :home)
    get("/docs", PageController, :docs)
    get("/docs/:section", PageController, :docs)
    get("/oauth/authorize", Auth.AuthorizeController, :authorize)
    get("/oauth/login", Auth.LoginController, :new)
    post("/oauth/login", Auth.LoginController, :create)
    post("/oauth/logout", Auth.LoginController, :delete)
  end

  scope "/", Backplane.Api do
    pipe_through(:oauth_api)

    get(
      "/.well-known/openid-configuration",
      Auth.DiscoveryController,
      :openid_configuration
    )

    get(
      "/.well-known/oauth-authorization-server",
      Auth.DiscoveryController,
      :authorization_server
    )

    get(
      "/.well-known/oauth-protected-resource/:resource",
      Auth.DiscoveryController,
      :protected_resource
    )

    get("/oauth/jwks", Auth.JwksController, :index)
    get("/oauth/userinfo", Auth.UserinfoController, :show)
    post("/oauth/token", Auth.TokenController, :token)
    post("/oauth/introspect", Auth.IntrospectController, :introspect)
    post("/oauth/revoke", Auth.RevokeController, :revoke)
  end

  scope "/" do
    pipe_through(:skills_api)

    forward("/host-agent", Backplane.Skills.HostAgentApiRouter)
    forward("/skills", Backplane.Skills.ApiRouter)
  end

  scope "/api" do
    pipe_through(:memory_api)
    forward("/memory", Backplane.Memory.Router)
  end

  match(:*, "/*path", Backplane.Api.NotFoundPlug, [])
end
