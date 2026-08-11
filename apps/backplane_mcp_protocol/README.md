# Backplane.McpProtocol MCP

[![hex.pm](https://img.shields.io/hexpm/v/backplane_mcp_protocol.svg)](https://hex.pm/packages/backplane_mcp_protocol)
[![docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/backplane_mcp_protocol)
[![Hex Downloads](https://img.shields.io/hexpm/dt/backplane_mcp_protocol)](https://hex.pm/packages/backplane_mcp_protocol)

Model Context Protocol (MCP) implementation in Elixir.

## Overview

Backplane.McpProtocol is the MCP protocol app used by Backplane and is also
published on Hex. It provides client and server implementations for the
[Model Context Protocol](https://spec.modelcontextprotocol.io/) under the
Backplane.McpProtocol namespace. The package supports the modern
`2026-07-28` protocol over Streamable HTTP and stdio while preserving the
legacy initialization and session behavior required by older protocol versions.

## Installation

```elixir
def deps do
  [
    {:backplane_mcp_protocol, "~> 0.4.4"}
  ]
end
```

Inside the Backplane umbrella, use `{:backplane_mcp_protocol, in_umbrella: true}`
instead.

## Quick Start

### Server

```elixir
# Define a tool as a Component (compile-time registration)
defmodule MyApp.Echo do
  @moduledoc "Echoes everything the user says to the LLM"

  use Backplane.McpProtocol.Server.Component, type: :tool

  alias Backplane.McpProtocol.Server.Response

  schema do
    field :text, :string, required: true, max_length: 150, description: "the text to be echoed"
  end

  @impl true
  def execute(%{text: text}, frame) do
    {:reply, Response.text(Response.tool(), text), frame}
  end
end

defmodule MyApp.MCPServer do
  use Backplane.McpProtocol.Server,
    name: "My Server",
    version: "1.0.0",
    capabilities: [:tools]

  # Static component registration — dispatches to MyApp.Echo.execute/2
  component MyApp.Echo

  @impl true
  def init(_client_info, frame) do
    # Legacy sessions can also register tools dynamically via the Frame:
    # frame = register_tool(frame, "dynamic_tool", description: "...", input_schema: %{...})
    {:ok, frame}
  end

  # Use init_request/2 instead for request-local modern setup.
end

# Add to your application supervisor
children = [
  {MyApp.MCPServer, transport: :streamable_http}
]

# Add to your Phoenix router (if using HTTP)
forward "/mcp", Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, server: MyApp.MCPServer

# Or if using only Plug router
forward "/mcp", to: Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug, init_opts: [server: MyApp.MCPServer]
```

Now you can achieve your MCP server on `http://localhost:<port>/mcp`

### Client

```elixir
# Add to your application supervisor
children = [
  {Backplane.McpProtocol.Client,
   name: MyApp.MCPClient,
   transport: {:streamable_http, base_url: "http://localhost:4000"},
   client_info: %{"name" => "MyApp", "version" => "1.0.0"},
   protocol_version: :auto}
]

# Use the client
{:ok, result} = Backplane.McpProtocol.Client.call_tool(MyApp.MCPClient, "echo", %{text: "this will be echoed!"})
```

`:auto` is the default. It probes with modern `server/discover`, negotiates
`2026-07-28` when available, and falls back to legacy initialization only when
the transport provides protocol-defined evidence of a legacy peer. Pin a
version string when cross-era fallback is not wanted:

```elixir
protocol_version: "2025-06-18"
```

Modern HTTP requests are stateless, POST-only, and do not create an MCP
session. Legacy versions continue to use their existing initialization,
session, GET notification stream, and DELETE cleanup behavior.

## Documentation

For detailed guides and examples, see the files in `pages/`, including the
client, server, API reference, and authorization guides.

## Verification

From `apps/backplane_mcp_protocol`, run the package and release checks with the
umbrella dependency directory:

```bash
MIX_ENV=test MIX_DEPS_PATH=../../deps mix test
MIX_ENV=dev MIX_DEPS_PATH=../../deps mix docs
MIX_ENV=dev MIX_DEPS_PATH=../../deps mix hex.build --unpack
```

Run the frozen official conformance package in a second terminal after starting
the server harness:

```bash
MIX_ENV=test MIX_DEPS_PATH=../../deps mix run --no-halt test/conformance/server_runner.exs -- 4105
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 server --url http://127.0.0.1:4105/mcp --requirements 2026-07-28

MIX_ENV=test MIX_DEPS_PATH=../../deps mix compile
npx -y @modelcontextprotocol/conformance@0.2.0-alpha.11 client --command "ERL_LIBS=../../_build/test/lib elixir test/conformance/client_runner.exs --" --requirements 2026-07-28
```

The package revision and scored requirement counts are recorded in the
[conformance pin](https://github.com/gsmlg-opt/backplane/blob/main/apps/backplane_mcp_protocol/test/conformance/PIN.md).

## Examples

The app includes Elixir implementation examples using `plug` and `phoenix` apps:

1. [upcase-server](/priv/dev/upcase/README.md): `plug` based MCP server using streamable_http
2. [echo-elixir](/priv/dev/echo-elixir/README.md): `phoenix` based MCP server using sse
3. [ascii-server](/priv/dev/ascii/README.md): `phoenix_live_view` based MCP server using streamable_http and UI

## License

LGPL-v3 License. See [LICENSE](./LICENSE) for details.
