import Config

config :backplane_api, Backplane.Api.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :backplane_admin, Backplane.Admin.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
