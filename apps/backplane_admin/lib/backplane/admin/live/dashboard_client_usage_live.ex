defmodule Backplane.Admin.DashboardClientUsageLive do
  use Backplane.Admin, :live_view

  alias Backplane.Clients
  alias Backplane.LLM.LogQuery, as: LlmLogQuery
  alias Backplane.MCP.LogQuery, as: McpLogQuery

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/dashboard/usage/clients", loading: true, rows: [])}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load_usage(socket)}

  defp load_usage(socket) do
    clients = safe_call(&Clients.list_clients/0, [])
    llm = safe_call(&LlmLogQuery.aggregate_by_client/0, %{})
    mcp = safe_call(&McpLogQuery.aggregate_by_client/0, %{})

    rows =
      Enum.map(clients, fn client ->
        %{
          id: client.id,
          name: client.name,
          active: client.active,
          llm: Map.get(llm, client.id, %{requests: 0, models: []}),
          mcp: Map.get(mcp, client.id, %{requests: 0, rpc_methods: [], tools: []})
        }
      end)

    assign(socket, loading: false, rows: rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">Client Usage</h1>
        <p class="mt-1 text-sm text-on-surface-variant">LLM models and MCP operations used by each registered client.</p>
      </div>

      <div :if={@loading} class="text-sm text-on-surface-variant">Loading client usage...</div>
      <div :if={!@loading and @rows == []} class="text-sm text-on-surface-variant">
        No clients configured.
        <.link navigate={~p"/system/clients"} class="text-primary underline">Manage clients</.link>
      </div>

      <div :if={!@loading and @rows != []} class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <.dm_card :for={row <- @rows} id={"client-usage-#{row.id}"} variant="bordered">
          <:title>
            <div class="flex items-center justify-between gap-3">
              <span class="font-semibold">{row.name}</span>
              <.dm_badge variant={if(row.active, do: "success", else: "neutral")} size="sm">
                {if(row.active, do: "Active", else: "Inactive")}
              </.dm_badge>
            </div>
          </:title>

          <div class="space-y-6">
            <section>
              <div class="mb-2 flex items-center justify-between">
                <h2 class="font-semibold">LLM Usage</h2>
                <span class="text-sm text-on-surface-variant">{format_number(row.llm.requests)} requests</span>
              </div>
              <div :if={row.llm.models == []} class="text-sm text-on-surface-variant">No LLM usage recorded.</div>
              <.dm_table :if={row.llm.models != []} id={"client-#{row.id}-models"} data={row.llm.models} hover zebra>
                <:col :let={model} label="Model"><code>{model.model}</code></:col>
                <:col :let={model} label="Requests">{format_number(model.requests)}</:col>
                <:col :let={model} label="Input Tokens">{format_input_tokens(model)}</:col>
                <:col :let={model} label="Output Tokens">{format_number(model.output_tokens)}</:col>
              </.dm_table>
            </section>

            <section>
              <div class="mb-2 flex items-center justify-between">
                <h2 class="font-semibold">MCP Usage</h2>
                <span class="text-sm text-on-surface-variant">{format_number(row.mcp.requests)} requests</span>
              </div>
              <div :if={row.mcp.rpc_methods == [] and row.mcp.tools == []} class="text-sm text-on-surface-variant">No MCP usage recorded.</div>
              <div :if={row.mcp.rpc_methods != []}>
                <h3 class="mb-1 text-sm text-on-surface-variant">RPC methods</h3>
                <.dm_table id={"client-#{row.id}-rpc"} data={row.mcp.rpc_methods} hover zebra>
                  <:col :let={method} label="Method"><code>{method.method}</code></:col>
                  <:col :let={method} label="Requests">{format_number(method.requests)}</:col>
                  <:col :let={method} label="Avg Duration">{format_number(method.avg_duration_ms)} ms</:col>
                </.dm_table>
              </div>
              <div :if={row.mcp.tools != []} class="mt-4">
                <h3 class="mb-1 text-sm text-on-surface-variant">Tools</h3>
                <.dm_table id={"client-#{row.id}-tools"} data={row.mcp.tools} hover zebra>
                  <:col :let={tool} label="Tool"><code>{tool.tool}</code></:col>
                  <:col :let={tool} label="Calls">{format_number(tool.requests)}</:col>
                </.dm_table>
              </div>
            </section>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp format_number(value) when is_integer(value) do
    value |> Integer.to_string() |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  defp format_number(value), do: to_string(value || 0)

  defp format_input_tokens(%{input_tokens: input_tokens, cached_tokens: cached_tokens}) do
    percentage =
      if input_tokens > 0 do
        cached_tokens * 100 / input_tokens
      else
        0.0
      end

    "#{format_number(input_tokens)} / #{format_number(cached_tokens)} (#{:erlang.float_to_binary(percentage, decimals: 1)}%)"
  end

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
