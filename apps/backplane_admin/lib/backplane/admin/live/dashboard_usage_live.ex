defmodule Backplane.Admin.DashboardUsageLive do
  use Backplane.Admin, :live_view

  alias Backplane.LLM.UsageQuery
  alias Backplane.Metrics

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: current_path(socket.assigns.live_action), usage: nil, metrics: %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :mcp ->
          assign(socket,
            current_path: current_path(:mcp),
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
    assigns = assign(assigns, :method_counters, method_counters(assigns.metrics))

    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">MCP Usage</h1>
        <.link navigate={~p"/admin/dashboard/usage/llm"} class="text-sm text-primary underline">
          LLM Usage
        </.link>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.dm_stat title="Total MCP Requests" value={format_number(counter(@metrics, "mcp_requests_total"))} />
        <.dm_stat title="Tool Calls" value={format_number(counter(@metrics, "tool_calls_total"))} />
        <.dm_stat title="Successful Tool Calls" value={format_number(counter(@metrics, "tool_calls_success"))} />
        <.dm_stat title="Tool Call Errors" value={format_number(counter(@metrics, "tool_calls_errors"))} />
      </div>

      <section>
        <h2 class="mb-3 text-lg font-semibold">MCP Requests By Method</h2>
        <div :if={@method_counters == []} class="text-sm text-on-surface-variant">
          No MCP request metrics recorded yet.
        </div>
        <.dm_table :if={@method_counters != []} id="mcp-methods-table" data={@method_counters} hover zebra>
          <:col :let={row} label="Method">
            <code>{row.method}</code>
          </:col>
          <:col :let={row} label="Requests">{format_number(row.count)}</:col>
        </.dm_table>
      </section>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">LLM Usage</h1>
        <.link navigate={~p"/admin/dashboard/usage/mcp"} class="text-sm text-primary underline">
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

  defp current_path(:mcp), do: "/admin/dashboard/usage/mcp"
  defp current_path(_), do: "/admin/dashboard/usage/llm"

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

  defp method_counters(metrics) do
    metrics
    |> Map.get(:counters, %{})
    |> Enum.filter(fn {name, _count} ->
      String.starts_with?(name, "mcp_requests.") and name != "mcp_requests_total"
    end)
    |> Enum.map(fn {"mcp_requests." <> method, count} -> %{method: method, count: count} end)
    |> Enum.sort_by(& &1.method)
  end

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
