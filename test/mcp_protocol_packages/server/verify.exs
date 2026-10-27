defmodule McpServerConsumer.Server do
  use Backplane.McpProtocol.Server,
    name: "standalone",
    version: "1.0.0",
    capabilities: [],
    protocol_versions: ["2026-07-28"]
end

dependencies = Enum.map(Mix.Dep.load_and_cache(), & &1.app)

if Enum.any?([:finch, :mint], &(&1 in dependencies)),
  do: raise("unexpected Finch/Mint dependency")

{:ok, server} =
  Backplane.McpProtocol.Server.Supervisor.start_link(McpServerConsumer.Server,
    transport: {:streamable_http, start: true}
  )

{:ok, listener} =
  Gaoxy.HTTP.start_link(
    plug:
      {Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug,
       server: McpServerConsumer.Server},
    ip: {127, 0, 0, 1},
    port: 0
  )

%{local: {:ok, {_, port}}} = Gaoxy.info(listener, :http)

request = %{
  "jsonrpc" => "2.0",
  "method" => "server/discover",
  "id" => "standalone",
  "params" => %{
    "_meta" => %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  }
}

{:ok, %{status: 200, body: body}} =
  Backplane.McpProtocol.HTTP.request(
    Backplane.McpProtocol.HTTP.build(
      :post,
      "http://127.0.0.1:#{port}/mcp",
      %{
        "mcp-protocol-version" => "2026-07-28",
        "mcp-method" => "server/discover",
        "accept" => "application/json, text/event-stream"
      },
      JSON.encode!(request)
    )
  )

%{
  "id" => "standalone",
  "result" => %{"_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "standalone"}}}
} = JSON.decode!(body)

started = Enum.map(Application.started_applications(), &elem(&1, 0))

if Enum.any?([:finch, :mint], &(&1 in started)),
  do: raise("unexpected started Finch/Mint application")

IO.puts("standalone_dependencies: #{inspect(dependencies)}")
IO.puts("standalone_started_applications: #{inspect(started)}")
Supervisor.stop(server)
GenServer.stop(listener)

alias Backplane.McpProtocol.Transport.STDIO

{:ok, transport} =
  STDIO.start_link(
    name: nil,
    client: self(),
    cleanup: :verified,
    command: System.find_executable("cat"),
    activation_id: "standalone-guardian"
  )

receive do
  {:"$gen_cast", :negotiate} -> :ok
after
  2_000 -> raise "guardian startup was not acknowledged"
end

wire =
  JSON.encode!(%{"jsonrpc" => "2.0", "id" => "echo", "result" => %{"text" => "汉字\r\n"}}) <> "\n"

:ok = STDIO.send_message(transport, wire, timeout: 1_000)

receive do
  {:"$gen_cast", {:response, ^wire}} -> :ok
after
  2_000 -> raise "guardian did not preserve target stdout"
end

{:ok, %{version: 1, phase: :closed, outcome: :confirmed} = report} =
  STDIO.close(transport, timeout: 2_000)

{:ok, ^report} = STDIO.cleanup_status(transport)
{:ok, ^report} = STDIO.close(transport, timeout: 50)
GenServer.stop(transport)
IO.puts("Standalone MCP server graph, protocol request and verified stdio: PASS")
