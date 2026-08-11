# Authorization

Backplane.McpProtocol supports OAuth 2.1 bearer token authorization for HTTP-based transports (`:streamable_http` and `:sse`). STDIO transport is exempt per the MCP specification.

## Quick Start

```elixir
defmodule MyApp.MCPServer do
  use Backplane.McpProtocol.Server,
    transport: :streamable_http,
    authorization: [
      authorization_servers: ["https://auth.example.com"],
      resource: "https://api.example.com",
      scopes_supported: ["tools:read", "tools:write"],
      validator: {Backplane.McpProtocol.Server.Authorization.JWTValidator,
        jwks_uri: "https://auth.example.com/.well-known/jwks.json"}
    ]
end
```

Every request to the server must include a valid bearer token:

```http
Authorization: Bearer <token>
```

Requests without a token or with an invalid token receive a `401 Unauthorized` response with a `WWW-Authenticate` header pointing to the protected resource metadata document.

## Validators

### JWT Validator

Validates signed JWTs by fetching the authorization server's JWKS. Requires the optional `:jose` dependency:

```elixir
{:jose, "~> 1.11"}
```

```elixir
validator: {Backplane.McpProtocol.Server.Authorization.JWTValidator,
  jwks_uri: "https://auth.example.com/.well-known/jwks.json",
  issuer: "https://auth.example.com"   # optional iss validation
}
```

JWKS responses are cached in `:persistent_term` for 5 minutes per `jwks_uri`.

### Introspection Validator

Validates tokens via RFC 7662 introspection. Works with any token format:

```elixir
validator: {Backplane.McpProtocol.Server.Authorization.IntrospectionValidator,
  introspection_endpoint: "https://auth.example.com/introspect",
  client_id: "my-resource-server",       # optional Basic auth
  client_secret: "my-secret"
}
```

### Custom Validator

Implement `Backplane.McpProtocol.Server.Authorization.Validator` for any other token format:

```elixir
defmodule MyApp.TokenValidator do
  @behaviour Backplane.McpProtocol.Server.Authorization.Validator

  @impl true
  def validate_token(token, _config) do
    case MyApp.Token.verify(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Scope Enforcement

Declare required scopes on individual components:

```elixir
defmodule MyApp.WriteFileTool do
  use Backplane.McpProtocol.Server.Component, type: :tool, scopes: ["files:write"]

  schema do
    field :path, :string, required: true
    field :content, :string, required: true
  end

  def execute(params, frame) do
    # Only reached when caller has "files:write" scope
    {:reply, Response.text(Response.tool(), "Written"), frame}
  end
end
```

Callers missing required scopes receive an MCP execution error indicating `insufficient_scope` with the required and granted scopes in the error payload.

## Accessing Claims in Handlers

Validated claims are available on the frame:

```elixir
def execute(params, frame) do
  subject = Backplane.McpProtocol.Server.Frame.subject(frame)      # "user-123"
  scopes  = Backplane.McpProtocol.Server.Frame.scopes(frame)       # ["tools:read", "tools:write"]
  auth    = Backplane.McpProtocol.Server.Frame.authorization(frame) # full claims map

  if Backplane.McpProtocol.Server.Frame.has_scope?(frame, "admin") do
    # privileged path
  end

  {:reply, Response.text(Response.tool(), "Hello #{subject}"), frame}
end
```

## Protected Resource Metadata

The server serves the RFC 9728 metadata document at:

```http
GET /.well-known/oauth-protected-resource
```

Response:

```json
{
  "resource": "https://api.example.com",
  "authorization_servers": ["https://auth.example.com"],
  "scopes_supported": ["tools:read", "tools:write"],
  "bearer_methods_supported": ["header"]
}
```

The SSE and Streamable HTTP plugs handle this path inline when they are mounted at the root of the host. If you mount the MCP plug under a sub-path (e.g. `/sse`, `/mcp`), requests to `/.well-known/oauth-protected-resource` never reach the plug. In that case mount `Backplane.McpProtocol.Server.Transport.WellKnown` as a sibling route:

```elixir
# Plug.Router
forward "/.well-known/oauth-protected-resource",
  to: Backplane.McpProtocol.Server.Transport.WellKnown,
  init_opts: [server: MyApp.MCPServer]

forward "/sse", to: Backplane.McpProtocol.Server.Transport.SSE.Plug,
  init_opts: [server: MyApp.MCPServer, mode: :sse]
```

```elixir
# Phoenix
forward "/.well-known/oauth-protected-resource",
  Backplane.McpProtocol.Server.Transport.WellKnown,
  server: MyApp.MCPServer
```

## Standards

| Standard | Coverage |
|---|---|
| RFC 6750 | Bearer token usage on `Authorization` header |
| RFC 9728 | Protected Resource Metadata (`/.well-known/oauth-protected-resource`) |
| RFC 8707 | Audience validation (`aud` claim against `resource` URI) |
| RFC 7662 | Token Introspection |
| RFC 7519 + 7517 | JWT + JWKS verification |

## Modern Client Authorization

`2026-07-28` client integrations can use
`Backplane.McpProtocol.Client.Authorization` to apply the protocol's
authorization-server binding and registration rules. The application still
owns browser redirects, PKCE, authorization-code exchange, and token refresh.

Validate the RFC 9207 `iss` value exactly. Do not URI-normalize or case-fold it:

```elixir
alias Backplane.McpProtocol.Client.Authorization

:ok = Authorization.validate_issuer(expected_issuer, returned_issuer, authorization_server_metadata)
```

Choose registration in protocol priority order: pre-registered credentials,
Client ID Metadata Documents, then deprecated Dynamic Client Registration when
explicitly enabled:

```elixir
{:ok, selection} =
  Authorization.select_registration(authorization_server_metadata,
    pre_registered: configured_client,
    client_id_metadata_document: "https://client.example/.well-known/oauth-client",
    dynamic_client_registration: false
  )
```

When DCR is used, include the correct OIDC `application_type`:

```elixir
metadata = Authorization.registration_metadata(metadata, :native)
```

Persist client credentials with a secure adapter implementing
`Backplane.McpProtocol.Client.Authorization.CredentialStore`. Keys are the
exact validated `{issuer, client_id}` pair; adapter configuration must not
contain the credential values themselves.

```elixir
config :backplane_mcp_protocol, :authorization_credential_store,
  adapter: MyApp.OAuthCredentialStore

alias Backplane.McpProtocol.Client.Authorization.CredentialStore

:ok = CredentialStore.put(validated_issuer, client_id, credentials)
{:ok, credentials} = CredentialStore.fetch(validated_issuer, client_id)
```

Bearer tokens, client credentials, authorization codes, mirrored sensitive
parameters, and MRTR `requestState` values must not be added to application
logs or telemetry.
