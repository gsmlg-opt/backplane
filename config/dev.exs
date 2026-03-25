import Config

config :backplane, Backplane.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", "postgres"),
  socket_dir: System.get_env("PGHOST", "/tmp"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :debug
