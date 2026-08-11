# API Reference

A quick reference for the most commonly used functions. Looking for more detailed examples? Check out our guides.

## Client API

### Starting a Client

Add `Backplane.McpProtocol.Client` directly to your supervision tree:

```elixir
{Backplane.McpProtocol.Client,
 name: MyApp.MCPClient,
 transport: {:stdio, command: "cmd", args: ["arg1"]},
 client_info: %{"name" => "MyApp", "version" => "1.0.0"},
 protocol_version: :auto}
```

**Required Options:**

- `name` - Process name (atom or `{:via, ...}` tuple)
- `transport` - Transport configuration tuple
- `client_info` - Map with `"name"` and `"version"` keys

**Optional Options:**

- `capabilities` - Capabilities map (default: `%{}`)
- `protocol_version` - `:auto` (default) or an explicitly pinned MCP version

**Transport Options:**

- `{:stdio, command: "cmd", args: ["arg1", "arg2"]}`
- `{:streamable_http, base_url: "http://localhost:8000"}`
- `{:websocket, base_url: "ws://localhost:8000"}`
- `{:sse, base_url: "http://localhost:8000"}` _(deprecated — use `:streamable_http` instead)_

`2026-07-28` is supported over stdio and Streamable HTTP. Pin a legacy version
for WebSocket or SSE.

### Client Functions

All functions take a client process name or PID as the first argument:

```elixir
Backplane.McpProtocol.Client.list_tools(MyApp.MCPClient)
```

**Connection Management:**

- `ping/1,2` - Check responsiveness on legacy peers; unsupported by `2026-07-28`
- `close/1` - Close the connection gracefully
- `await_ready/1,2` - Wait for modern discovery or legacy initialization
- `get_protocol_info/1,2` - Inspect the selected era, version, and peer metadata
- `set_log_level/2` - Set a legacy peer's logging threshold; unsupported by `2026-07-28`

**Discovery:**

- `get_server_info/1,2` - Get server information
- `get_server_capabilities/1,2` - Get server capabilities

**Tools:**

- `list_tools/1,2` - List available tools
- `call_tool/2,3,4` - Call a tool with arguments

**Resources:**

- `list_resources/1,2` - List available resources (supports pagination)
- `read_resource/2,3` - Read a specific resource

**Prompts:**

- `list_prompts/1,2` - List available prompts (supports pagination)
- `get_prompt/2,3,4` - Get a prompt with arguments

**Autocompletion:**

- `complete/3,4` - Get completion suggestions

**Modern Subscriptions:**

- `listen_subscriptions/2,3` - Open and acknowledge a `subscriptions/listen` stream
- `close_subscription/2,3` - Cancel a subscription using its transport-specific mechanism

Subscription owners receive `{:mcp_subscription, handle, notification}` and
`{:mcp_subscription_closed, handle, reason}` messages. Connection loss closes
the handle; callers must listen again after reconnecting if they still want
events.

### Options

Functions that make requests accept options:

- `timeout: milliseconds` - Request timeout (default: 30_000)
- `meta: map` - Application request metadata; modern protocol-reserved metadata is merged by the client
- `progress: keyword` - Progress token and optional callback

### Protocol Selection

`:auto` starts with modern `server/discover`, negotiates `2026-07-28`, and uses
legacy initialization only after a protocol-defined legacy signal. Explicit
version strings are pins and never fall back across eras. Modern Streamable
HTTP sends `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and safe
schema-declared `Mcp-Param-*` mirrors.

## Server API

### Module Definition

```elixir
use Backplane.McpProtocol.Server, options
```

**Required Options:**

- `name` - Your server name (string)
- `version` - Your server version (string)
- `capabilities` - List of capabilities to expose

### Starting a Server

```elixir
{MyApp.Server, transport: transport_config}
```

**Transport Options:**

- `:stdio` - Standard input/output
- `{:streamable_http, port: 8080}` - HTTP server
- `:none` - No transport (for embedding)

### Server Callbacks

```elixir
@behaviour Backplane.McpProtocol.Server.Behaviour

# Optional initialization
def init(arg, frame) do
  {:ok, frame}
end

# Optional initialization for one stateless 2026-07-28 request
def init_request(request_context, frame) do
  {:ok, frame}
end

# Handle incoming requests (optional)
def handle_request(request, frame) do
  {:reply, result, frame}
end

# Handle notifications (optional)
def handle_notification(notification, frame) do
  {:noreply, frame}
end
```

### Component Definition

#### Tools

```elixir
use Backplane.McpProtocol.Server.Component, type: :tool

alias Backplane.McpProtocol.Server.Response

# Schema definition
schema do
  field :name, :string, required: true
  field :age, :integer, min: 0
end

# Execution callback
def execute(params, frame) do
  {:reply, Response.text(Response.tool(), result), frame}
end
```

#### Resources

```elixir
use Backplane.McpProtocol.Server.Component,
  type: :resource,
  uri: "resource://type/name"

alias Backplane.McpProtocol.Server.Response

# Read callback
def read(params, frame) do
  {:reply, Response.text(Response.resource(), content), frame}
end
```

#### Prompts

```elixir
use Backplane.McpProtocol.Server.Component, type: :prompt

alias Backplane.McpProtocol.Server.Response

# Schema for arguments
schema do
  field :context, :string
end

# Get messages callback
def get_messages(params, frame) do
  response = Response.prompt() |> Response.user_message("...")
  {:reply, response, frame}
end
```

### Component Registration

```elixir
defmodule MyApp.Server do
  use Backplane.McpProtocol.Server, ...

  # Register components
  component MyApp.MyTool
  component MyApp.MyResource
  component MyApp.MyPrompt
end
```

## Schema DSL

The DSL covers the common Peri-compatible subset. Modern tools also preserve
raw JSON Schema 2020-12 maps on the wire, including unknown keywords, `$defs`,
composition, and references. A client that cannot compile a received schema
retains the tool but disables local validation for it. External network `$ref`
resolution is disabled by default. Modern `structuredContent` accepts every
JSON value, including explicit `null`.

Available field types and validations:

```elixir
schema do
  field :string_field, :string,
    required: true,
    min_length: 1,
    max_length: 100,
    regex: ~r/pattern/,
    description: "A string field"

  field :number_field, :number,
    min: 0,
    max: 100,
    description: "A number field"

  field :integer_field, :integer,
    min: 0,
    max: 1000,
    description: "An integer field"

  field :boolean_field, :boolean,
    default: false,
    description: "A boolean field"

  field :enum_field, :enum,
    required: true,
    description: "An enum field",
    values: ~w(option1 option2 option3)

  field :list_field, {:list, :string},
    description: "A list of strings"

  # Nested objects using embeds_one
  embeds_one :profile, required: true do
    field :name, :string, required: true
    field :age, :integer, min: 0, max: 150
  end

  # Arrays of objects using embeds_many
  embeds_many :tags do
    field :name, :string, required: true
    field :value, :string
  end
end
```

## Return Values

### Client Returns

Most client functions return:

- `{:ok, %{result: data}}` - Successful response
- `{:ok, %{is_error: true, result: error}}` - Tool-level error
- `{:error, reason}` - Protocol or connection error

### Server Returns

Component callbacks return:

- `{:reply, %Response{}, frame}` - Success with response
- `{:noreply, frame}` - No reply needed
- `{:error, %Error{}, frame}` - Error with structured error

Server callbacks return:

- `{:reply, result, frame}` - Reply with result
- `{:noreply, frame}` - No reply
- `{:stop, reason, frame}` - Stop the server

## Error Handling

Errors are automatically formatted according to MCP protocol. You can return:

- String error messages
- Error tuples
- Exceptions (will be caught and formatted)

## Useful Mix Tasks

**Interactive Testing:**

- `mix backplane.mcp_protocol.stdio.interactive Module` - Test with STDIO
- `mix backplane.mcp_protocol.streamable_http.interactive Module` - Test with HTTP

**Development:**

- `mix compile --force` - Recompile all components
- `mix test` - Run tests

The modern `io.modelcontextprotocol/tasks` extension is not enabled in this
release. Legacy Tasks remain supported for `2025-11-25` peers.

## Need More?

This reference covers the essential API. For detailed examples and patterns:

- [Building a Client](building-a-client.md)
- [Building a Server](building-a-server.md)
- [Recipes](recipes.md)
- [Authorization](authorization.md)

Remember: the protocol complexity is handled for you. Focus on what your application does best.
