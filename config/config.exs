import Config

config :backplane, ecto_repos: [Backplane.Repo]

config :backplane, Backplane.Repo,
  database: "backplane_#{config_env()}",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true

config :backplane, Oban,
  repo: Backplane.Repo,
  queues: [default: 10, indexing: 5, sync: 3]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
