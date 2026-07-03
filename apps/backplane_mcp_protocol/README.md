# Backplane.McpProtocol MCP

[![hex.pm](https://img.shields.io/hexpm/v/backplane_mcp_protocol.svg)](https://hex.pm/packages/backplane_mcp_protocol)
[![docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/backplane_mcp_protocol)
[![Hex Downloads](https://img.shields.io/hexpm/dt/backplane_mcp_protocol)](https://hex.pm/packages/backplane_mcp_protocol)

Backplane-local Model Context Protocol (MCP) implementation in Elixir.

## Overview

Backplane.McpProtocol is the umbrella-local MCP protocol app used by Backplane. It provides client and server implementations for the [Model Context Protocol](https://spec.modelcontextprotocol.io/) under the `Backplane.McpProtocol` namespace.

## Installation

```elixir
def deps do
  [
    {:backplane_mcp_protocol, in_umbrella: true}
  ]
end
```

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
    # You can also register tools dynamically at runtime via the Frame:
    # frame = register_tool(frame, "dynamic_tool", description: "...", input_schema: %{...})
    {:ok, frame}
  end
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
   protocol_version: "2025-06-18"}
]

# Use the client
{:ok, result} = Backplane.McpProtocol.Client.call_tool(MyApp.MCPClient, "echo", %{text: "this will be echoed!"})
```

## Documentation

For detailed guides and examples, see the files in `pages/`.

## Examples

The app includes Elixir implementation examples using `plug` and `phoenix` apps:

1. [upcase-server](/priv/dev/upcase/README.md): `plug` based MCP server using streamable_http
2. [echo-elixir](/priv/dev/echo-elixir/README.md): `phoenix` based MCP server using sse
3. [ascii-server](/priv/dev/ascii/README.md): `phoenix_live_view` based MCP server using streamable_http and UI

## License

LGPL-v3 License. See [LICENSE](./LICENSE) for details.
