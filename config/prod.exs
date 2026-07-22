import Config

config :backplane, env: :prod
config :backplane_auth, allow_insecure_resource_origins: false

config :backplane_api, Backplane.Api.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :backplane_admin, Backplane.Admin.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
