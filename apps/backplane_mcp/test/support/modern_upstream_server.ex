defmodule Backplane.Test.ModernUpstreamServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "backplane-modern-upstream-test",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2026-07-28"]

  alias Backplane.McpProtocol.Server.Component.Schema
  alias Backplane.McpProtocol.Server.{Frame, Handlers, Response}

  @impl true
  def init_request(_context, frame) do
    {:ok,
     Frame.register_tool(frame, "echo",
       description: "Echo arguments",
       input_schema: Schema.raw(%{"type" => "object", "additionalProperties" => true})
     )}
  end

  @impl true
  def handle_request(request, frame), do: Handlers.handle(request, __MODULE__, frame)

  @impl true
  def handle_tool_call("echo", arguments, frame) do
    {:reply, Response.structured(Response.tool(), arguments), frame}
  end

  defmodule Plug do
    @moduledoc false

    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    alias Backplane.McpProtocol.Server.Transport.StreamableHTTP.Plug,
      as: StreamableHTTPPlug

    @impl Elixir.Plug
    def init(opts) do
      %{
        observer: Keyword.fetch!(opts, :observer),
        delegate: StreamableHTTPPlug.init(server: Backplane.Test.ModernUpstreamServer)
      }
    end

    @impl Elixir.Plug
    def call(conn, %{observer: observer, delegate: delegate}) do
      send(observer, {
        :modern_upstream_request,
        %{
          method: List.first(get_req_header(conn, "mcp-method")),
          session_headers: get_req_header(conn, "mcp-session-id")
        }
      })

      StreamableHTTPPlug.call(conn, delegate)
    end
  end
end
