import Config

config :backplane_mcp_protocol, log: true

if config_env() == :dev do
  config :logger, level: :debug
end
