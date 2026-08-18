defmodule Backplane.McpProtocol.Server.Component.ToolIconsTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Server.Component.Tool
  alias Backplane.McpProtocol.Server.Frame
  alias Backplane.McpProtocol.Server.Handlers.Tools

  defmodule StaticIconTool do
    @moduledoc "Static tool with modern icon metadata"

    use Backplane.McpProtocol.Server.Component, type: :tool

    alias Backplane.McpProtocol.Server.Response

    schema do
      %{}
    end

    @impl true
    def icons do
      [
        %{
          "src" => "https://example.test/static.svg",
          "mimeType" => "image/svg+xml",
          "theme" => "dark"
        }
      ]
    end

    @impl true
    def execute(_params, frame), do: {:reply, Response.text(Response.tool(), "ok"), frame}
  end

  defmodule StaticIconServer do
    @moduledoc false

    use Backplane.McpProtocol.Server,
      name: "static-icon-server",
      version: "1.0.0",
      capabilities: [:tools]

    component(StaticIconTool)

    @impl true
    def init(_arg, frame), do: {:ok, frame}

    @impl true
    def handle_notification(_notification, frame), do: {:noreply, frame}
  end

  test "tool JSON preserves title, icons, and _meta using protocol keys" do
    tool =
      struct!(Tool,
        name: "lookup",
        title: "Lookup",
        description: "Find one record",
        input_schema: %{"type" => "object"},
        icons: [%{"src" => "https://example.test/icon.svg"}],
        meta: %{"vendor" => %{"stable" => true}}
      )

    assert %{
             "name" => "lookup",
             "title" => "Lookup",
             "description" => "Find one record",
             "inputSchema" => %{"type" => "object"},
             "icons" => [%{"src" => "https://example.test/icon.svg"}],
             "_meta" => %{"vendor" => %{"stable" => true}}
           } = JSON.decode!(JSON.encode!(tool))
  end

  test "tool JSON omits nil optional presentation fields" do
    tool = %Tool{name: "lookup", description: "Find one record", input_schema: %{}}
    decoded = JSON.decode!(JSON.encode!(tool))

    for optional <- ~w(title outputSchema annotations icons _meta execution) do
      refute Map.has_key?(decoded, optional)
    end
  end

  test "runtime registration preserves presentation metadata without enabling tasks" do
    icons = [%{"src" => "https://example.test/icon.svg", "mimeType" => "image/svg+xml"}]
    meta = %{"vendor" => %{"stable" => true}}

    frame =
      Frame.register_tool(Frame.new(), "lookup",
        title: "Lookup",
        description: "Find one record",
        input_schema: %{"type" => "object"},
        icons: icons,
        meta: meta
      )

    assert %Tool{
             title: "Lookup",
             icons: ^icons,
             meta: ^meta,
             task_support: :forbidden
           } = frame.tools["lookup"]

    decoded = JSON.decode!(JSON.encode!(frame.tools["lookup"]))
    assert decoded["icons"] == icons
    assert decoded["_meta"] == meta
    refute Map.has_key?(decoded, "execution")
  end

  test "static component icons survive generated server parsing and tools/list" do
    icons = StaticIconTool.icons()

    assert [%Tool{name: "static_icon_tool", icons: ^icons}] =
             StaticIconServer.__components__(:tool)

    assert {:reply, %{"tools" => [%Tool{icons: ^icons} = listed]}, %Frame{}} =
             Tools.handle_list(%{}, Frame.new(), StaticIconServer)

    assert JSON.decode!(JSON.encode!(listed))["icons"] == icons
  end
end
