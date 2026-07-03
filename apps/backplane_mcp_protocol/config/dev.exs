import Config

# Enable session persistence in development
if System.get_env("ENABLE_SESSION_STORE") == "true" do
  config :backplane_mcp_protocol, :session_store,
    enabled: true,
    adapter: Backplane.McpProtocol.Server.Session.Store.Redis,
    redis_url: System.get_env("REDIS_URL", "redis://localhost:6379/0"),
    pool_size: String.to_integer(System.get_env("REDIS_POOL_SIZE", "10")),
    ttl: String.to_integer(System.get_env("SESSION_TTL", "1800000")),
    namespace: System.get_env("SESSION_NAMESPACE", "backplane_mcp_protocol:sessions"),
    connection_name: :backplane_mcp_protocol_redis
end
