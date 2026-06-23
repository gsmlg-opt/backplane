import Config

# Bun/Tailwind binary paths for devenv environments (all envs).
# Keep this in runtime config so local installations can be detected at boot
# without baking machine-specific paths into compile-time config.
if bun_path = System.get_env("MIX_BUN_PATH") || System.find_executable("bun") do
  bun_version = System.cmd(bun_path, ["--version"]) |> elem(0) |> String.trim()
  config :bun, path: bun_path, version: bun_version
end

if tailwind_path = System.get_env("MIX_TAILWIND_PATH") || System.find_executable("tailwindcss") do
  tailwind_str = System.cmd(tailwind_path, ["--help"]) |> elem(0)
  tailwind_version = Regex.run(~r/tailwindcss v([0-9.]+)/, tailwind_str) |> Enum.at(1)
  config :tailwind, path: tailwind_path, version: tailwind_version
end

if config_env() == :prod do
  config :backplane_system, Backplane.Repo, types: Backplane.PostgrexTypes

  config_path = System.get_env("BACKPLANE_CONFIG", "backplane.toml")

  if File.exists?(config_path) do
    backplane_config = Backplane.Config.load!(config_path)

    # Database
    if db_url = get_in(backplane_config, [:database, :url]) do
      config :backplane_system, Backplane.Repo, url: db_url
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

    # Upstream MCP servers to proxy
    config :backplane, upstreams: backplane_config[:upstream] || []

    # Pre-seeded clients (upserted on boot)
    config :backplane, client_seeds: backplane_config[:clients] || []

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

    # Telemetry settings
    if telemetry = backplane_config[:telemetry] do
      config :backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
        log_to_logger: telemetry.log_to_logger,
        log_to_console: telemetry.log_to_console,
        log_to_file: telemetry.log_to_file
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
  server? = System.get_env("PHX_SERVER") in ["1", "true", "TRUE", "yes", "YES"]

  api_port =
    case System.get_env("BACKPLANE_API_PORT") || System.get_env("BACKPLANE_PORT") ||
           System.get_env("PORT") do
      nil -> 4100
      port_str -> String.to_integer(port_str)
    end

  admin_port =
    case System.get_env("BACKPLANE_ADMIN_PORT") do
      nil -> 4101
      port_str -> String.to_integer(port_str)
    end

  config :backplane,
    secret_key_base: secret_key_base,
    api_url: System.get_env("BACKPLANE_API_URL", "http://#{host}:#{api_port}"),
    admin_url: System.get_env("BACKPLANE_ADMIN_URL", "http://#{host}:#{admin_port}")

  port =
    case System.get_env("BACKPLANE_PORT") || System.get_env("PORT") do
      nil -> 4100
      port_str -> String.to_integer(port_str)
    end

  config :backplane_web, BackplaneWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: server?
end
