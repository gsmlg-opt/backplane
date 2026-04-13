defmodule BackplaneWeb.ToolsLive do
  use BackplaneWeb, :live_view

  alias Backplane.Registry.ToolRegistry

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/admin/hub/tools",
       loading: true,
       search: "",
       selected: nil,
       test_args: "{}",
       test_result: nil,
       test_running: false
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    tools = safe_call(fn -> ToolRegistry.list_all() end, [])
    {:noreply, assign(socket, loading: false, tools: tools, filtered_tools: tools)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    filtered =
      if query == "" do
        socket.assigns.tools
      else
        q = String.downcase(query)

        Enum.filter(socket.assigns.tools, fn tool ->
          String.contains?(String.downcase(tool.name), q) or
            String.contains?(String.downcase(tool.description || ""), q)
        end)
      end

    {:noreply, assign(socket, search: query, filtered_tools: filtered)}
  end

  def handle_event("select", %{"name" => name}, socket) do
    tool = Enum.find(socket.assigns.tools, &(&1.name == name))
    {:noreply, assign(socket, selected: tool, test_args: "{}", test_result: nil)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, selected: nil, test_result: nil)}
  end

  def handle_event("test_call", %{"args" => args_json}, socket) do
    tool = socket.assigns.selected

    if tool do
      case Jason.decode(args_json) do
        {:ok, arguments} ->
          socket = assign(socket, test_running: true, test_args: args_json)

          result =
            try do
              Backplane.Transport.McpHandler.dispatch_tool_call(tool.name, arguments)
            rescue
              e -> {:error, Exception.message(e)}
            end

          formatted =
            case result do
              {:ok, data} -> %{status: :ok, data: inspect(data, pretty: true, limit: :infinity)}
              {:error, msg} -> %{status: :error, data: to_string(msg)}
            end

          {:noreply, assign(socket, test_result: formatted, test_running: false)}

        {:error, _} ->
          {:noreply,
           assign(socket,
             test_result: %{status: :error, data: "Invalid JSON arguments"},
             test_args: args_json
           )}
      end
    else
      {:noreply, socket}
    end
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="flex gap-2 mb-6">
        <.dm_btn
          variant={if @current_path in ["/admin/hub", "/admin/hub/upstreams"], do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/upstreams")}
        >
          Upstreams
        </.dm_btn>
        <.dm_btn
          variant={if @current_path == "/admin/hub/skills", do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/skills")}
        >
          Skills
        </.dm_btn>
        <.dm_btn
          variant={if @current_path == "/admin/hub/tools", do: "primary", else: nil}
          phx-click={JS.navigate(~p"/admin/hub/tools")}
        >
          Tools
        </.dm_btn>
      </div>

      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Tools</h1>
        <span class="text-sm text-on-surface-variant">{length(@filtered_tools)} tools</span>
      </div>

      <div class="mb-4">
        <.dm_input
          id="tools-search"
          type="search"
          name="query"
          value={@search}
          placeholder="Search tools..."
          phx-keyup="search"
          phx-debounce="200"
        />
      </div>

      <div class="space-y-2">
        <.dm_card
          :for={tool <- @filtered_tools}
          variant="bordered"
          class={[
            "cursor-pointer transition-colors",
            @selected && @selected.name == tool.name && "ring-2 ring-primary"
          ]}
          phx-click="select"
          phx-value-name={tool.name}
        >
          <:title>
            <div class="flex items-center justify-between">
              <span class="text-sm font-mono text-primary">{tool.name}</span>
              <.dm_badge
                variant={if tool.origin == :native, do: "info", else: "tertiary"}
                size="sm"
              >
                {origin_label(tool.origin)}
              </.dm_badge>
            </div>
          </:title>
          <p class="text-xs text-on-surface-variant mt-1 line-clamp-1">{tool.description}</p>
        </.dm_card>
      </div>

      <div
        :if={@selected}
        class="fixed inset-y-0 right-0 w-96 bg-surface-container border-l border-outline-variant p-6 overflow-y-auto z-50"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-bold">Tool Detail</h2>
          <.dm_btn variant="ghost" size="xs" phx-click="close_detail">X</.dm_btn>
        </div>
        <div class="space-y-4">
          <div>
            <dt class="text-xs text-on-surface-variant">Name</dt>
            <dd class="text-sm font-mono text-primary">{@selected.name}</dd>
          </div>
          <div>
            <dt class="text-xs text-on-surface-variant">Description</dt>
            <dd class="text-sm text-on-surface">{@selected.description}</dd>
          </div>
          <div>
            <dt class="text-xs text-on-surface-variant">Origin</dt>
            <dd class="text-sm text-on-surface">{origin_label(@selected.origin)}</dd>
          </div>
          <div>
            <dt class="text-xs text-on-surface-variant">Input Schema</dt>
            <dd class="text-xs font-mono text-on-surface bg-surface-container-high rounded p-3 overflow-x-auto">
              <pre>{Jason.encode!(@selected.input_schema || %{}, pretty: true)}</pre>
            </dd>
          </div>

          <div class="border-t border-outline-variant pt-4">
            <h3 class="text-sm font-medium mb-2">Test Call</h3>
            <form phx-submit="test_call">
              <.dm_textarea
                id="test-call-args"
                name="args"
                rows={4}
                value={@test_args}
                placeholder={~s({"key": "value"})}
                class="font-mono text-xs"
              />
              <.dm_btn
                type="submit"
                variant="primary"
                disabled={@test_running}
                class="mt-2 w-full"
              >
                {if @test_running, do: "Running...", else: "Call Tool"}
              </.dm_btn>
            </form>

            <div :if={@test_result} class="mt-3">
              <.dm_badge
                variant={if @test_result.status == :ok, do: "success", else: "error"}
                size="sm"
                class="mb-1"
              >
                {if @test_result.status == :ok, do: "Success", else: "Error"}
              </.dm_badge>
              <pre class="text-xs font-mono text-on-surface bg-surface-container-high rounded p-3 overflow-x-auto whitespace-pre-wrap max-h-64 overflow-y-auto">{@test_result.data}</pre>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp origin_label(:native), do: "native"
  defp origin_label({:upstream, name}), do: "upstream:#{name}"
  defp origin_label(other), do: to_string(other)
end
