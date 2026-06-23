import Config

config :backplane_system, Backplane.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", "postgres"),
  socket_dir: System.get_env("PGHOST", "/tmp"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  types: Backplane.PostgrexTypes

config :backplane_web, dev_routes: true
config :backplane_api, dev_routes: true

secret_key_base =
  "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only_do_not_use"

config :backplane,
  secret_key_base: secret_key_base,
  api_url: "http://localhost:4220",
  admin_url: "http://localhost:4221"

config :backplane_web, BackplaneWeb.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4220],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:backplane, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:backplane, ~w(--sourcemap=inline --watch)]}
  ]

config :backplane_api, Backplane.Api.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4220],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    tailwind_api: {Tailwind, :install_and_run, [:backplane_api, ~w(--watch)]},
    bun_api: {Bun, :install_and_run, [:backplane_api, ~w(--sourcemap=inline --watch)]}
  ]

config :backplane_web, BackplaneWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/backplane_web/lib/backplane_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :backplane_api, Backplane.Api.Endpoint,
  live_reload: [
    patterns: [
      ~r"apps/backplane_api/priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/backplane_api/lib/backplane/api/(controllers|channels|components)/.*(ex|heex)$"
    ]
  ]

config :logger, level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :backplane_host_agent,
  start_on_application: false,
  telemetry_logger: true

config :backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
  log_to_logger: true,
  log_to_console: true,
  log_to_file: "/tmp/backplane-telemetry.jsonl"
