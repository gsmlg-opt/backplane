import Config

boolean = fn env ->
  System.get_env(env) in ["1", "true"]
end

config :backplane_mcp_protocol, compile_cli?: boolean.("BACKPLANE_MCP_PROTOCOL_COMPILE_CLI")

config :logger, :default_formatter,
  format: "[$level] $message $metadata\n",
  metadata: [:mcp_server, :mcp_client, :mcp_client_name, :mcp_transport]

# Session store configuration - disabled by default
# To enable Redis persistence, uncomment and configure:
# config :backplane_mcp_protocol, :session_store,
#   enabled: true,
#   adapter: Backplane.McpProtocol.Server.Session.Store.Redis,
#   redis_url: System.get_env("REDIS_URL", "redis://localhost:6379/0"),
#   pool_size: 10,
#   ttl: 1800,  # TTL is in ms
#   namespace: "backplane_mcp_protocol:sessions",
#   connection_name: :backplane_mcp_protocol_redis

if config_env() != :prod, do: import_config("#{config_env()}.exs")
