import Config

parse_csv_env = fn name ->
  name
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
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

    # Telemetry settings (deprecated: prefer RuntimeSink; legacy key honored one release)
    if telemetry = backplane_config[:telemetry] do
      config :backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
        log_to_logger: telemetry.log_to_logger,
        log_to_console: telemetry.log_to_console,
        log_to_file: telemetry.log_to_file

      config :backplane_telemetry, Backplane.Observability.RuntimeSink,
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

  api_url = System.get_env("BACKPLANE_API_URL", "http://#{host}:#{api_port}")
  admin_url = System.get_env("BACKPLANE_ADMIN_URL", "http://#{host}:#{admin_port}")
  bootstrap_admin_emails = parse_csv_env.("BACKPLANE_BOOTSTRAP_ADMIN_EMAILS")

  config :backplane,
    secret_key_base: secret_key_base,
    api_url: api_url,
    admin_url: admin_url,
    bootstrap_admin_emails: bootstrap_admin_emails

  config :boruta, Boruta.Oauth, issuer: api_url

  config :backplane_api, Backplane.Api.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: api_port],
    secret_key_base: secret_key_base,
    server: server?

  config :backplane_admin, Backplane.Admin.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: admin_port],
    secret_key_base: secret_key_base,
    server: server?
end
