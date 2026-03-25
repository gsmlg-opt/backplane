import Config

if config_env() == :prod do
  config_path = System.get_env("BACKPLANE_CONFIG", "backplane.toml")

  if File.exists?(config_path) do
    backplane_config = Backplane.Config.load!(config_path)

    # Database
    if db_url = get_in(backplane_config, [:database, :url]) do
      config :backplane, Backplane.Repo, url: db_url
    end

    # Backplane server settings
    bp = backplane_config[:backplane]

    if bp do
      config :backplane,
        host: bp.host,
        port: bp.port,
        auth_token: bp.auth_token,
        config_path: config_path
    end

    # Git providers
    github_providers = backplane_config[:github] || []
    gitlab_providers = backplane_config[:gitlab] || []

    config :backplane,
      git_providers: %{
        github: github_providers,
        gitlab: gitlab_providers
      }

    # Projects to index
    config :backplane, projects: backplane_config[:projects] || []

    # Upstream MCP servers to proxy
    config :backplane, upstreams: backplane_config[:upstream] || []

    # Skill sources
    config :backplane, skill_sources: backplane_config[:skills] || []
  end
end
