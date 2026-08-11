defmodule ModernStubServer.AlphaTool do
  @moduledoc false
  use Backplane.McpProtocol.Server.Component, type: :tool

  alias Backplane.McpProtocol.Server.Response

  schema do
    field(:value, :string, required: false)
  end

  @impl true
  def execute(_params, frame), do: {:reply, Response.text(Response.tool(), "alpha"), frame}
end

defmodule ModernStubServer.ZetaTool do
  @moduledoc false
  use Backplane.McpProtocol.Server.Component, type: :tool

  alias Backplane.McpProtocol.Server.Response

  schema do
    field(:value, :string, required: false)
  end

  @impl true
  def execute(_params, frame), do: {:reply, Response.text(Response.tool(), "zeta"), frame}
end

defmodule ModernStubServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-stub",
    version: "1.0.0",
    capabilities: [:tools, :prompts, :resources, :completion],
    protocol_versions: ["2026-07-28", "2026-07-28", "2025-11-25"],
    instructions: "Use the test tools deterministically."

  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.Server.Context
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Handlers
  alias Backplane.McpProtocol.Server.Response

  component(ModernStubServer.ZetaTool, name: "zeta")
  component(ModernStubServer.AlphaTool, name: "alpha")

  @impl true
  def init_request(context, frame) do
    notify(frame, {:modern_init_request, context})

    case get_in(context.request, ["params", "_testInit"]) do
      "raise" -> raise "private init failure"
      "throw" -> throw({:private, context.request_state})
      "exit" -> exit({:private, context.request_state})
      "timeout" -> Process.sleep(250)
      "invalid" -> :invalid
      "error" -> {:error, Error.protocol(:invalid_params), frame}
      "tamper-context" -> {:ok, %{prepare_frame(frame) | context: %Context{auth: %{sub: "spoofed"}}}}
      _other -> {:ok, prepare_frame(frame)}
    end
  end

  @impl true
  def init(_client_info, _frame), do: raise("legacy init must not run for modern requests")

  @impl true
  def handle_request(request, frame) do
    notify(frame, {:modern_handle_request, request["method"], frame.assigns[:init_count]})
    notify(frame, {:modern_callback_context, frame.context})

    case get_in(request, ["params", "_testCallback"]) do
      "raise" -> raise "private callback failure"
      "throw" -> throw({:private, frame.context.request_state})
      "exit" -> exit({:private, frame.context.request_state})
      "invalid" -> :invalid
      "noreply" -> {:noreply, frame}
      _other -> Handlers.handle(request, __MODULE__, frame)
    end
  end

  @impl true
  def handle_tool_call("route", arguments, frame) do
    result = %{
      "arguments" => arguments,
      "initCount" => frame.assigns[:init_count],
      "requestNonce" => frame.assigns[:request_nonce]
    }

    {:reply, Response.structured(Response.tool(), result), frame}
  end

  @impl true
  def handle_completion(_ref, _argument, frame) do
    {:reply, Response.completion_values(Response.completion(), ["alpha"]), frame}
  end

  defp prepare_frame(frame) do
    next_count = Map.get(frame.assigns, :init_count, 0) + 1

    frame
    |> Frame.assign(:init_count, next_count)
    |> Frame.assign(:request_nonce, System.unique_integer([:positive, :monotonic]))
    |> Frame.register_tool("middle", input_schema: %{})
    |> Frame.register_tool("route",
      input_schema:
        Backplane.McpProtocol.Server.Component.Schema.raw(%{
          "type" => "object",
          "properties" => %{
            "region" => %{
              "type" => "string",
              "x-mcp-header" => "Region"
            }
          }
        })
    )
  end

  defp notify(frame, message) do
    if test_pid = frame.assigns[:test_pid], do: send(test_pid, message)
    :ok
  end
end

defmodule ModernNoToolsServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-no-tools",
    version: "1.0.0",
    capabilities: [],
    protocol_versions: ["2026-07-28"]
end

defmodule ModernLegacyOnlyServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-legacy-only",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2025-11-25"]
end

defmodule ModernRaisingMetadataServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-raising-metadata",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2026-07-28"]

  @impl true
  def server_capabilities, do: raise("private metadata failure")
end

defmodule ModernSlowMetadataServer do
  @moduledoc false

  use Backplane.McpProtocol.Server,
    name: "modern-slow-metadata",
    version: "1.0.0",
    capabilities: [:tools],
    protocol_versions: ["2026-07-28"]

  @impl true
  def supported_protocol_versions do
    Process.sleep(250)
    ["2026-07-28"]
  end
end
