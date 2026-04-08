import Config

# Bun/Tailwind binary paths for devenv environments (all envs)
if bun_path = System.get_env("MIX_BUN_PATH") do
  config :bun, path: bun_path
end

if tailwind_path = System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: tailwind_path
end

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

    # Pre-seeded clients (upserted on boot)
    config :backplane, client_seeds: backplane_config[:clients] || []

    # Embeddings configuration (optional — entire pipeline inert when absent)
    if embeddings = backplane_config[:embeddings] do
      config :backplane, embeddings: embeddings
    end

    # Audit settings
    if audit = backplane_config[:audit] do
      config :backplane,
        audit_enabled: audit.enabled,
        audit_retention_days: audit.retention_days
    end

    # Cache settings
    if cache = backplane_config[:cache] do
      config :backplane,
        cache_enabled: cache.enabled,
        cache_max_entries: cache.max_entries
    end
  end

  # Phoenix Endpoint — production configuration
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "localhost")

  port =
    case System.get_env("BACKPLANE_PORT") || System.get_env("PORT") do
      nil -> 4100
      port_str -> String.to_integer(port_str)
    end

  config :backplane_web, BackplaneWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

end
