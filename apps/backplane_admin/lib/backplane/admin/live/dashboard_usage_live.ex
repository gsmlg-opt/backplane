defmodule Backplane.Admin.DashboardUsageLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.UsageQuery
  alias Backplane.MCP.LogQuery, as: McpLogQuery
  alias Backplane.Metrics

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: current_path(socket.assigns.live_action),
       usage: nil,
       mcp_usage: nil,
       metrics: %{}
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :mcp ->
          assign(socket,
            current_path: current_path(:mcp),
            mcp_usage: safe_call(fn -> McpLogQuery.aggregate() end, empty_mcp_usage()),
            metrics: safe_call(fn -> Metrics.snapshot() end, %{})
          )

        _ ->
          assign(socket,
            current_path: current_path(:llm),
            usage: safe_call(fn -> UsageQuery.aggregate() end, empty_usage())
          )
      end

    {:noreply, socket}
  end

  @impl true
  def render(%{live_action: :mcp} = assigns) do
    assigns = assign(assigns, :method_counters, rpc_method_rows(assigns.mcp_usage))

    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">MCP Usage</h1>
        <.link navigate={~p"/dashboard/usage/llm"} class="text-sm text-primary underline">
          LLM Usage
        </.link>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.dm_stat title="Total MCP Requests" value={format_number(@mcp_usage.total_requests)} />
        <.dm_stat title="Avg Duration" value={"#{format_number(@mcp_usage.avg_duration_ms)} ms"} />
        <.dm_stat title="Runtime tool calls" value={format_number(counter(@metrics, "tool_calls_total"))} />
        <.dm_stat title="Runtime MCP requests" value={format_number(counter(@metrics, "mcp_requests_total"))} />
      </div>

      <section>
        <h2 class="mb-3 text-lg font-semibold">MCP Requests By RPC Method (historical)</h2>
        <div :if={@method_counters == []} class="text-sm text-on-surface-variant">
          No MCP request logs recorded yet.
        </div>
        <.dm_table :if={@method_counters != []} id="mcp-methods-table" data={@method_counters} hover zebra>
          <:col :let={row} label="Method">
            <code>{row.method}</code>
          </:col>
          <:col :let={row} label="Requests">{format_number(row.count)}</:col>
        </.dm_table>
      </section>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Outcomes</h2>
        <div :if={@mcp_usage.by_outcome == %{}} class="text-sm text-on-surface-variant">
          No outcome data recorded yet.
        </div>
        <div :if={@mcp_usage.by_outcome != %{}} class="flex flex-wrap gap-2">
          <.dm_badge :for={{outcome, count} <- Enum.sort(@mcp_usage.by_outcome)} variant="neutral">
            {outcome}: {format_number(count)}
          </.dm_badge>
        </div>
      </section>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">LLM Usage</h1>
        <.link navigate={~p"/dashboard/usage/mcp"} class="text-sm text-primary underline">
          MCP Usage
        </.link>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.dm_stat title="Total Requests" value={format_number(@usage.total_requests)} />
        <.dm_stat title="Input Tokens" value={format_number(@usage.total_input_tokens)} />
        <.dm_stat title="Output Tokens" value={format_number(@usage.total_output_tokens)} />
        <.dm_stat title="Average Latency" value={"#{format_number(@usage.avg_latency_ms)} ms"} />
      </div>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Usage By Model</h2>
        <div :if={@usage.by_model == []} class="text-sm text-on-surface-variant">
          No LLM usage logs recorded yet.
        </div>
        <.dm_table :if={@usage.by_model != []} id="llm-model-usage-table" data={@usage.by_model} hover zebra>
          <:col :let={row} label="Model">
            <code>{row.model}</code>
          </:col>
          <:col :let={row} label="Requests">{format_number(row.requests)}</:col>
          <:col :let={row} label="Input Tokens">{format_number(row.input_tokens)}</:col>
          <:col :let={row} label="Output Tokens">{format_number(row.output_tokens)}</:col>
        </.dm_table>
      </section>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Status Codes</h2>
        <div :if={@usage.by_status == %{}} class="text-sm text-on-surface-variant">
          No status data recorded yet.
        </div>
        <div :if={@usage.by_status != %{}} class="flex flex-wrap gap-2">
          <.dm_badge :for={{status, count} <- Enum.sort(@usage.by_status)} variant="neutral">
            {status}: {format_number(count)}
          </.dm_badge>
        </div>
      </section>
    </div>
    """
  end

  defp current_path(:mcp), do: "/dashboard/usage/mcp"
  defp current_path(_), do: "/dashboard/usage/llm"

  defp empty_usage do
    %{
      total_requests: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      avg_latency_ms: 0,
      by_model: [],
      by_status: %{}
    }
  end

  defp empty_mcp_usage do
    %{
      total_requests: 0,
      avg_duration_ms: 0,
      by_operation: [],
      by_rpc_method: [],
      by_outcome: %{}
    }
  end

  defp rpc_method_rows(%{by_rpc_method: rows}) do
    Enum.map(rows, fn row -> %{method: row.rpc_method, count: row.requests} end)
  end

  defp rpc_method_rows(_), do: []

  defp counter(metrics, name), do: get_in(metrics, [:counters, name]) || 0

  defp format_number(nil), do: "0"
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: to_string(value)

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
