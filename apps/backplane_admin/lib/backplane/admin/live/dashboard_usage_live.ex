defmodule Backplane.Admin.DashboardUsageLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.Components.UsageTimeRange, only: [usage_time_range: 1]

  alias Backplane.Admin.Components.UsageTimeRange
  alias Backplane.LLM.UsageQuery
  alias Backplane.MCP.LogQuery, as: McpLogQuery
  alias Backplane.Metrics

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: current_path(socket.assigns.live_action),
       usage: nil,
       daily_tokens: nil,
       mcp_usage: nil,
       metrics: %{},
       range: "today"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :mcp ->
          assign(socket,
            current_path: current_path(:mcp),
            mcp_usage: safe_call(fn -> McpLogQuery.aggregate() end, empty_mcp_usage()),
            metrics: safe_call(fn -> Metrics.snapshot() end, %{})
          )

        _ ->
          {range, time_range} = UsageTimeRange.parse(params["range"])

          assign(socket,
            current_path: current_path(:llm),
            range: range,
            daily_tokens: safe_call(fn -> UsageQuery.daily_tokens() end, nil),
            usage: safe_call(fn -> UsageQuery.aggregate(time_range) end, empty_usage())
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

      <.daily_token_chart rows={@daily_tokens} />

      <.usage_time_range id="llm-usage-range" action={~p"/dashboard/usage/llm"} selected={@range} />

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.dm_stat title="Total Requests" value={format_number(@usage.total_requests)} />
        <.dm_stat title="Input Tokens" value={format_number(@usage.total_input_tokens)} />
        <.dm_stat title="Output Tokens" value={format_number(@usage.total_output_tokens)} />
        <.dm_stat title="Average Latency" value={"#{format_number(@usage.avg_latency_ms)} ms"} />
      </div>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Usage By Provider</h2>
        <div :if={@usage.by_provider == []} class="text-sm text-on-surface-variant">
          No LLM usage logs recorded yet.
        </div>
        <.dm_table :if={@usage.by_provider != []} id="llm-provider-usage-table" data={@usage.by_provider} hover zebra>
          <:col :let={row} label="Provider">
            <code>{row.provider}</code>
          </:col>
          <:col :let={row} label="Requests">{format_number(row.requests)}</:col>
          <:col :let={row} label="Input Tokens">{format_number(row.input_tokens)}</:col>
          <:col :let={row} label="Cached Tokens">{format_number(row.cached_tokens)}</:col>
          <:col :let={row} label="Output Tokens">{format_number(row.output_tokens)}</:col>
          <:col :let={row} label="Alias Calls">{format_number(row.alias_calls)}</:col>
        </.dm_table>
      </section>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Usage By Provider / Model</h2>
        <div :if={provider_model_rows(@usage.by_provider) == []} class="text-sm text-on-surface-variant">
          No provider model usage recorded yet.
        </div>
        <.dm_table
          :if={provider_model_rows(@usage.by_provider) != []}
          id="llm-provider-model-usage-table"
          data={provider_model_rows(@usage.by_provider)}
          hover
          zebra
        >
          <:col :let={row} label="Provider"><code>{row.provider}</code></:col>
          <:col :let={row} label="Model"><code>{row.model}</code></:col>
          <:col :let={row} label="Requests">{format_number(row.requests)}</:col>
          <:col :let={row} label="Input Tokens">{format_number(row.input_tokens)}</:col>
          <:col :let={row} label="Cached Tokens">{format_number(row.cached_tokens)}</:col>
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

  attr(:rows, :list, default: nil)

  defp daily_token_chart(assigns) do
    rows = assigns.rows || []
    total = Enum.sum(Enum.map(rows, &(&1.input_tokens + &1.output_tokens)))
    peak = Enum.reduce(rows, 1, &max(&1.input_tokens + &1.output_tokens, &2))
    assigns = assign(assigns, total: total, peak: peak)

    ~H"""
    <.dm_card id="llm-daily-tokens" class="min-w-0">
      <:title>
        <h2 class="flex items-center gap-2 text-lg font-semibold">
          <.dm_mdi name="chart-bar" class="h-5 w-5" /> Daily Token Usage
        </h2>
      </:title>
      <p class="mb-4 text-sm text-on-surface-variant">
        Last 30 days · UTC · Includes today · Independent of the filters below
      </p>
      <p :if={is_nil(@rows)} class="text-sm text-on-surface-variant">
        Daily token usage is temporarily unavailable.
      </p>
      <div :if={@rows}>
        <p class="mb-4 text-2xl font-semibold tabular-nums">
          {format_number(@total)} <span class="text-sm font-normal text-on-surface-variant">tokens</span>
        </p>
        <p :if={@total == 0} class="mb-3 text-sm text-on-surface-variant">
          No token usage recorded in the last 30 days.
        </p>
        <div class="overflow-x-auto">
          <div id="llm-daily-tokens-chart" class="relative min-w-[600px]" role="group" aria-label="Daily token usage over the last 30 days">
            <svg
              viewBox="0 0 960 260"
              class="w-full"
              aria-hidden="true"
            >
              <g :for={fraction <- [0, 0.5, 1]}>
                <line x1="64" x2="954" y1={220 - fraction * 200} y2={220 - fraction * 200} class="stroke-outline-variant" />
                <text x="54" y={224 - fraction * 200} text-anchor="end" class="fill-on-surface-variant text-[11px]">
                  {compact_tokens(round(@peak * fraction))}
                </text>
              </g>
              <g :for={{row, index} <- Enum.with_index(@rows)}>
                <text
                  :if={rem(index, 5) == 0 or index == 29}
                  x={79.5 + index * 29.5}
                  y="244"
                  text-anchor="middle"
                  class="fill-on-surface-variant text-[11px]"
                >
                  {Calendar.strftime(row.date, "%m/%d")}
                </text>
              </g>
            </svg>
            <div class="absolute grid grid-cols-[repeat(30,minmax(0,1fr))]" style="top: 7.6923%; bottom: 15.3846%; left: 6.6667%; right: 1.1458%">
              <.dm_popover
                :for={row <- @rows}
                id={"daily-tokens-#{row.date}"}
                trigger_mode="hover"
                placement="top"
                class="h-max min-w-56 overflow-visible backdrop:bg-transparent"
              >
                <:trigger :let={trigger_attrs}>
                  <button
                    type="button"
                    data-date={Date.to_iso8601(row.date)}
                    data-total-tokens={row.input_tokens + row.output_tokens}
                    data-input-tokens={row.input_tokens}
                    data-cached-tokens={row.cached_tokens}
                    data-output-tokens={row.output_tokens}
                    aria-label={"#{row.date}: #{format_number(row.input_tokens + row.output_tokens)} tokens"}
                    class="group flex h-full w-full items-end justify-center focus-visible:outline-2 focus-visible:outline-primary"
                    {trigger_attrs}
                  >
                    <span
                      aria-hidden="true"
                      class="block min-h-px w-2/3 rounded-t-sm bg-primary group-hover:opacity-80"
                      style={"height: #{(row.input_tokens + row.output_tokens) / @peak * 100}%"}
                    ></span>
                  </button>
                </:trigger>
                <p class="mb-2 font-semibold">{Date.to_iso8601(row.date)}</p>
                <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-sm tabular-nums">
                  <dt>Total</dt><dd class="text-right font-semibold">{format_number(row.input_tokens + row.output_tokens)}</dd>
                  <dt>Input</dt><dd class="text-right">{format_number(row.input_tokens)}</dd>
                  <dt>Cached</dt><dd class="text-right">{format_number(row.cached_tokens)}</dd>
                  <dt>Output</dt><dd class="text-right">{format_number(row.output_tokens)}</dd>
                </dl>
              </.dm_popover>
            </div>
          </div>
        </div>
      </div>
    </.dm_card>
    """
  end

  defp compact_tokens(value) when value >= 1_000_000,
    do: "#{Float.round(value / 1_000_000, 1)}M"

  defp compact_tokens(value) when value >= 1_000,
    do: "#{Float.round(value / 1_000, 1)}K"

  defp compact_tokens(value), do: to_string(value)

  defp current_path(:mcp), do: "/dashboard/usage/mcp"
  defp current_path(_), do: "/dashboard/usage/llm"

  defp empty_usage do
    %{
      total_requests: 0,
      total_input_tokens: 0,
      total_output_tokens: 0,
      avg_latency_ms: 0,
      by_provider: [],
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

  defp provider_model_rows(providers) do
    Enum.flat_map(providers, fn provider ->
      Enum.map(provider.models, &Map.put(&1, :provider, provider.provider))
    end)
  end

  defp counter(metrics, name), do: get_in(metrics, [:counters, name]) || 0

  defp format_number(nil), do: "0"

  defp format_number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  defp format_number(value), do: to_string(value)

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
