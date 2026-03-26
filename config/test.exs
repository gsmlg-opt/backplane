import Config

config :backplane, Backplane.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "postgres")),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: "backplane_test#{System.get_env("MIX_TEST_PARTITION")}",
  socket_dir: System.get_env("PGHOST", "/tmp"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :backplane, Oban, testing: :inline

# We don't run a server during test
config :backplane, BackplaneWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_please",
  server: false

config :logger, level: :warning
