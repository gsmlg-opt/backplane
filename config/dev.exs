import Config

config :backplane, Backplane.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", "postgres"),
  socket_dir: System.get_env("PGHOST", "/tmp"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :backplane_web, dev_routes: true

config :backplane_web, BackplaneWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4100],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only_do_not_use",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:backplane, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:backplane, ~w(--sourcemap=inline --watch)]}
  ]

config :backplane_web, BackplaneWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"apps/backplane_web/lib/backplane_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :logger, level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
