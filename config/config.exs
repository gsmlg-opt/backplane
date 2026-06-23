import Config

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :backplane_system, ecto_repos: [Backplane.Repo]

config :backplane_system, Backplane.Repo,
  database: "backplane_#{config_env()}",
  hostname: "localhost",
  show_sensitive_data_on_connection_error: true

config :backplane, Oban,
  repo: Backplane.Repo,
  queues: [default: 10, indexing: 5, sync: 3, embeddings: 2, llm: 5, memory: 3],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Procedural extraction: nightly at 02:00
       {"0 2 * * *", BackplaneMemory.Workers.ProceduralWorker},
       # Fallback sweep: every 4 hours
       {"0 */4 * * *", BackplaneMemory.Workers.FallbackSweepWorker},
       # OAuth credential refresh: every 10 minutes
       {"*/10 * * * *", Backplane.Settings.OAuthTokenRefreshWorker}
     ]}
  ]

config :backplane_memory, repo: Backplane.Repo

config :backplane_monitor, repo: Backplane.Repo

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

config :backplane_api, Backplane.Api.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Backplane.Api.ErrorHTML, json: Backplane.Api.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backplane.PubSub,
  live_view: [signing_salt: "bkpln_api_lv_salt"]

config :backplane_admin, Backplane.Admin.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Backplane.Admin.ErrorHTML, json: Backplane.Admin.ErrorJSON],
    layout: false
  ],
  pubsub_server: Backplane.PubSub,
  live_view: [signing_salt: "bkpln_admin_lv_salt"]

# Bun bundler
config :bun,
  version: "1.3.3",
  backplane_api: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/backplane_api", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  backplane_admin: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/backplane_admin", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Tailwind v4
config :tailwind,
  version: "4.1.18",
  backplane_api: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/backplane_api", __DIR__)
  ],
  backplane_admin: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/backplane_admin", __DIR__)
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

# Relayixir is used as a library; Phoenix endpoints handle HTTP serving
config :relayixir, start_server: false

config :backplane, Backplane.Settings.OAuthRefresher,
  anthropic_token_url: "https://platform.claude.com/v1/oauth/token",
  openai_token_url: "https://auth.openai.com/oauth/token",
  google_token_url: "https://oauth2.googleapis.com/token",
  xai_token_url: "https://auth.x.ai/oauth2/token"

config :backplane_host_agent, start_on_application: true

config :backplane_telemetry, BackplaneTelemetry.TelemetryLogger,
  log_to_logger: true,
  log_to_console: false,
  log_to_file: nil

import_config "#{config_env()}.exs"
