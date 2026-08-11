# Building a Client

Let's explore how to connect your Elixir application to MCP servers. What possibilities open up when your code can leverage AI-enhanced services?

## Starting Simple

Starting a client is straightforward — add `Backplane.McpProtocol.Client` directly to your supervision tree:

```elixir
# In your Application.start/2
children = [
  {Backplane.McpProtocol.Client,
   name: MyApp.WeatherClient,
   transport: {:stdio, command: "weather-server", args: []},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: :auto}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The client automatically:

- Launches the weather server as a subprocess
- Negotiates capabilities
- Maintains the connection
- Handles all the protocol details

`:auto` is the default. The client probes `server/discover`, negotiates the
modern `2026-07-28` profile when available, and falls back to legacy
initialization only when the peer gives a protocol-defined legacy signal.
Malformed replies, transport failures, and arbitrary server errors do not
trigger a downgrade. Pin a version string when you require one era.

Wait for negotiation and inspect what was selected when startup ordering
matters:

```elixir
:ok = Backplane.McpProtocol.Client.await_ready(MyApp.WeatherClient)
%{era: era, protocol_version: version} =
  Backplane.McpProtocol.Client.get_protocol_info(MyApp.WeatherClient)
```

All client functions take a process name (or PID) as the first argument:

```elixir
Backplane.McpProtocol.Client.list_tools(MyApp.WeatherClient)
Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "get_weather", %{"location" => "Tokyo"})
```

## Discovering Capabilities

What can a connected server actually do? Let's find out:

```elixir
# What's this server about?
info = Backplane.McpProtocol.Client.get_server_info(MyApp.WeatherClient)
# => %{"name" => "Weather Server", "version" => "2.0.0", ...}

# What capabilities does it offer?
caps = Backplane.McpProtocol.Client.get_server_capabilities(MyApp.WeatherClient)
# => %{"tools" => %{"listChanged" => false}, ...}

# What tools are available?
{:ok, %{result: %{"tools" => tools}}} = Backplane.McpProtocol.Client.list_tools(MyApp.WeatherClient)

Enum.each(tools, fn tool ->
  IO.puts("#{tool["name"]}: #{tool["description"]}")
end)
# => get_weather: Get current weather for a location
# => get_forecast: Get weather forecast
```

Notice how we're exploring the server's interface dynamically?

## Using Tools

Now for the interesting part - actually using these discovered tools:

```elixir
# Simple tool call
{:ok, %{result: weather}} =
  Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "get_weather", %{
    "location" => "San Francisco"
  })

# Tool with complex parameters
{:ok, %{result: forecast}} =
  Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "get_forecast", %{
    "location" => "Tokyo",
    "days" => 5,
    "units" => "metric"
  })
```

What happens if something goes wrong?

```elixir
case Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "get_weather", %{"location" => ""}) do
  {:ok, %{is_error: false, result: weather}} ->
    # Success path

  {:ok, %{is_error: true, result: error}} ->
    # The tool itself reported an error
    IO.puts("Tool error: #{error["message"]}")

  {:error, error} ->
    # Protocol or connection error
    IO.puts("Connection error: #{inspect(error)}")
end
```

## Working with Resources

Some servers expose resources - think files, databases, or any readable content:

```elixir
# What resources are available?
{:ok, %{result: %{"resources" => resources}}} =
  Backplane.McpProtocol.Client.list_resources(MyApp.WeatherClient)

# Read a specific resource
{:ok, %{result: %{"contents" => contents}}} =
  Backplane.McpProtocol.Client.read_resource(MyApp.WeatherClient, "weather://stations/KSFO")

# Resources can have multiple content types
for content <- contents do
  case content do
    %{"text" => text} ->
      IO.puts("Text content: #{text}")

    %{"blob" => blob} ->
      IO.puts("Binary data: #{byte_size(blob)} bytes")
  end
end
```

## Transport Options

How does your client actually connect to servers? Let's explore the options:

```elixir
# Local subprocess
transport: {:stdio, command: "python", args: ["-m", "my_server"]}

# HTTP endpoint
transport: {:streamable_http, base_url: "http://localhost:8000"}

# WebSocket for real-time
transport: {:websocket, base_url: "ws://localhost:8000"}

# Server-Sent Events
transport: {:sse, base_url: "http://localhost:8000"}
```

Which transport should you choose?

- **STDIO**: Perfect for local tools and subprocess isolation
- **HTTP**: Great for remote services and web APIs
- **WebSocket**: Legacy client interoperability when explicitly pinned
- **SSE**: Deprecated legacy interoperability when explicitly pinned

The modern `2026-07-28` profile is supported over stdio and Streamable HTTP.
Pin an appropriate legacy version when using WebSocket or SSE.

## Advanced Patterns

### Multiple Client Instances

Need to connect to multiple servers? Just add multiple `Backplane.McpProtocol.Client` entries with different names:

```elixir
children = [
  {Backplane.McpProtocol.Client,
   name: MyApp.WeatherUS,
   transport: {:stdio, command: "weather-server", args: ["--region", "US"]},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: :auto},

  {Backplane.McpProtocol.Client,
   name: MyApp.WeatherEU,
   transport: {:stdio, command: "weather-server", args: ["--region", "EU"]},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: :auto}
]

# Use specific instances by name
Backplane.McpProtocol.Client.call_tool(MyApp.WeatherUS, "get_weather", %{location: "NYC"})
Backplane.McpProtocol.Client.call_tool(MyApp.WeatherEU, "get_weather", %{location: "Paris"})
```

### Dynamic Client Management

For scenarios where clients are created at runtime (e.g., user-configured MCP connections), use a `DynamicSupervisor`:

```elixir
# Start a DynamicSupervisor in your application
children = [
  {DynamicSupervisor, name: MyApp.MCPSupervisor, strategy: :one_for_one}
]

# Later, start clients dynamically
def connect_to_server(user_id, server_url) do
  name = :"mcp_client_#{user_id}"

  opts = [
    name: name,
    transport: {:streamable_http, base_url: server_url},
    client_info: %{"name" => "MyApp", "version" => "1.0.0"},
    protocol_version: :auto
  ]

  DynamicSupervisor.start_child(MyApp.MCPSupervisor, {Backplane.McpProtocol.Client, opts})
end

# Use the dynamic client by its name or PID
Backplane.McpProtocol.Client.list_tools(:"mcp_client_42")
```

### Using PIDs Directly

All client functions accept either a registered name or a PID. This is useful when working with dynamically started clients:

```elixir
{:ok, pid} = DynamicSupervisor.start_child(MyApp.MCPSupervisor, {Backplane.McpProtocol.Client, opts})

# Use the PID directly
Backplane.McpProtocol.Client.list_tools(pid)
Backplane.McpProtocol.Client.call_tool(pid, "my_tool", %{arg: "value"})
```

### Client Capabilities

Enable features your client supports using the `capabilities` option:

```elixir
{Backplane.McpProtocol.Client,
 name: MyApp.MCPClient,
 transport: {:stdio, command: "server"},
 client_info: %{"name" => "MyApp", "version" => "1.0.0"},
 capabilities: %{"roots" => %{}, "sampling" => %{}},
 protocol_version: :auto}
```

You can also use the `Backplane.McpProtocol.Client.parse_capability/2` helper to build capability maps from atom shorthand:

```elixir
capabilities =
  %{}
  |> Backplane.McpProtocol.Client.parse_capability(:roots)
  |> Backplane.McpProtocol.Client.parse_capability({:sampling, list_changed?: true})

# => %{"roots" => %{}, "sampling" => %{"listChanged" => true}}
```

### Handling Timeouts

Long-running operations? Adjust timeouts:

```elixir
# 5 minute timeout for slow operations
opts = [timeout: 300_000]
Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "analyze_historical_data", params, opts)
```

### Progress Tracking

Need to track progress on long-running operations? Here's how:

```elixir
# Generate a unique token for this operation
progress_token = Backplane.McpProtocol.MCP.ID.generate_progress_token()

# Option 1: Just track with a token
Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "analyze_data", params,
  progress: [token: progress_token]
)

# Option 2: Receive real-time updates
callback = fn ^progress_token, progress, total ->
  percentage = if total, do: "#{progress}/#{total}", else: "#{progress}"
  IO.puts("Progress: #{percentage}")
end

Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "analyze_data", params,
  progress: [token: progress_token, callback: callback]
)
```

The server sends progress notifications that your callback receives automatically.

### Modern Request Metadata and HTTP Headers

For `2026-07-28`, the client adds the negotiated protocol version, client
capabilities, and client identity to every request's `_meta`. Supply your own
non-reserved metadata with the existing `meta:` option:

```elixir
Backplane.McpProtocol.Client.call_tool(MyApp.WeatherClient, "get_weather", params,
  meta: %{"com.example/traceId" => trace_id}
)
```

Streamable HTTP requests also include `MCP-Protocol-Version`, `Mcp-Method`, and
`Mcp-Name` where applicable. After `tools/list`, primitive tool arguments marked
with `x-mcp-header` in the raw JSON Schema are projected to validated HTTP
headers. Unsafe mirrored strings, including values containing CR or LF, use
the protocol's base64 sentinel encoding; raw configured header values with CR
or LF are rejected.

### Multi-Round-Trip Requests

A modern `tools/call`, `prompts/get`, or `resources/read` result may be
`input_required`. The client invokes the configured roots, sampling, or
elicitation handler, then retries the original operation with `inputResponses`
and the server's opaque `requestState`. The original caller and deadline remain
attached to the operation. Treat `requestState` as sensitive and never log or
interpret it in application code.

### Modern Subscriptions

Use `subscriptions/listen` for modern long-lived notifications:

```elixir
{:ok, subscription} =
  Backplane.McpProtocol.Client.listen_subscriptions(MyApp.WeatherClient, [
    "notifications/tools/list_changed"
  ])

receive do
  {:mcp_subscription, ^subscription, notification} ->
    handle_notification(notification)
end

:ok = Backplane.McpProtocol.Client.close_subscription(MyApp.WeatherClient, subscription)
```

The returned handle is acknowledged before notifications are delivered. HTTP
uses an independent request-owned POST/SSE stream so normal calls remain
concurrent; stdio multiplexes notifications on the existing connection. A
connection loss closes explicit subscription handles. The client does not
silently recreate them, so callers must call `listen_subscriptions/3` again if
they still want events after reconnecting.

Legacy `resources/subscribe` and `resources/unsubscribe` remain available only
for legacy peers and return an unsupported-operation error against a modern
peer.

### JSON Schema and Structured Results

Modern catalog entries retain raw JSON Schema 2020-12 maps, including `$defs`,
composition keywords, references, and unknown extension keywords. The local
Peri adapter validates only its supported subset. If a received schema cannot
be compiled safely, the tool remains available with its raw schema and local
validation is disabled for that tool. External network `$ref` resolution is
disabled by default. `structuredContent` may be any JSON value, including an
array, primitive, boolean, or explicit `null`.

### Migrating from Legacy Initialization

For a new connection, remove an old `protocol_version: "2025-..."` pin or set
`:auto`, then use `await_ready/2` rather than assuming `initialize` ran. Modern
peers expose identity and capabilities through `server/discover`; requests are
independent and carry their own metadata. Keep an explicit legacy pin when your
application depends on session state, the GET notification stream, replay, or
session deletion.

The optional modern `io.modelcontextprotocol/tasks` extension is deferred in
this release. Existing Tasks APIs continue to work on the legacy `2025-11-25`
path.

## Graceful Shutdown

When you're done:

```elixir
Backplane.McpProtocol.Client.close(MyApp.WeatherClient)
```

This cleanly shuts down the connection and any associated resources.

## What's Next?

Now that you understand clients, what interests you?

- Building your own server to expose functionality?
- Exploring specific recipes for common patterns?
- Understanding how to handle errors gracefully?

The client handles all the protocol complexity - you just focus on using the capabilities. What will you connect to first?
