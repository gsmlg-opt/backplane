import Config

config :backplane, ecto_repos: [Backplane.Repo]

config :backplane, Backplane.Repo,
  database: "backplane_#{config_env()}",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true

config :backplane, Oban,
  repo: Backplane.Repo,
  queues: [default: 10, indexing: 5, sync: 3]

# Phoenix Endpoint
config :backplane_web, BackplaneWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BackplaneWeb.ErrorHTML, json: BackplaneWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backplane.PubSub,
  live_view: [signing_salt: "bkpln_lv_salt"]

# Bun bundler
config :bun,
  version: "1.2.0",
  backplane: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/backplane_web", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Tailwind v4
config :tailwind,
  version: "4.1.11",
  backplane: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/backplane_web", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :method,
    :path,
    :status,
    :duration_us,
    :remote_ip,
    :rpc_method,
    :upstream,
    :reason,
    :exit_status,
    :project_id,
    :error,
    :event,
    :provider,
    :result,
    :consecutive_failures,
    :tool,
    :duration_ms
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
