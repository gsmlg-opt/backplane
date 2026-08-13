import Config

qualification_real_pool? =
  System.get_env("BACKPLANE_MEMORY_QUALIFICATION_REAL_POOL") in ["1", "true"]

config :backplane_system, Backplane.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: "backplane_test#{System.get_env("MIX_TEST_PARTITION")}",
  socket_dir: System.get_env("PGHOST", "/tmp"),
  pool:
    if(qualification_real_pool?,
      do: DBConnection.ConnectionPool,
      else: Ecto.Adapters.SQL.Sandbox
    ),
  pool_size:
    if(qualification_real_pool?,
      do: System.schedulers_online() * 2,
      else: max(System.schedulers_online() * 2, 10)
    ),
  types: Backplane.PostgrexTypes

config :backplane, env: :test
config :backplane_auth, allow_insecure_resource_origins: true
config :backplane, llm_route_loader_enabled: false
config :backplane, Oban, testing: :inline
config :backplane_memory, projection_repair_enabled: false

secret_key_base =
  "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_please"

config :backplane,
  secret_key_base: secret_key_base,
  api_url: "http://localhost:4002",
  admin_url: "http://localhost:4003"

config :boruta, Boruta.Oauth, issuer: "http://localhost:4002"

config :backplane_api, Backplane.Api.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: secret_key_base,
  server: false

config :backplane_admin, Backplane.Admin.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: secret_key_base,
  server: false

config :backplane_host_agent, start_on_application: false

config :backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
  log_to_logger: false,
  log_to_console: false,
  log_to_file: nil

config :backplane_telemetry, start_logger: false

config :logger, level: :warning
