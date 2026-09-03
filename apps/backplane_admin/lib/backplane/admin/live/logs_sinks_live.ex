defmodule Backplane.Admin.LogsSinksLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.LogsComponents

  alias Backplane.Audit.Writer
  alias Backplane.LLM.LogWriter, as: LlmLogWriter
  alias Backplane.MCP.{LogWriter, ToolLogWriter}
  alias Backplane.Metrics
  alias Backplane.Observability

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/logs/sinks",
       loading: true,
       observability: nil,
       llm_writer: nil,
       mcp_writer: nil,
       mcp_tool_writer: nil,
       audit_writer: nil,
       metrics: %{}
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       loading: false,
       observability: safe_call(&Observability.health/0),
       llm_writer: safe_call(&LlmLogWriter.health/0),
       mcp_writer: safe_call(&LogWriter.health/0),
       mcp_tool_writer: safe_call(&ToolLogWriter.health/0),
       audit_writer: safe_call(&Writer.health/0),
       metrics: safe_call(&Metrics.snapshot/0, %{})
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-2 text-2xl font-bold">Observability Sinks</h1>
      <p class="mb-4 text-sm text-on-surface-variant">
        Writer queue health and runtime sink status. Historical usage lives in the logs tabs above.
      </p>

      <.logs_nav current="/system/logs/sinks" />

      <div :if={@loading}>
        <.loading_state />
      </div>

      <div :if={!@loading} class="space-y-6">
        <section>
          <h2 class="mb-3 text-lg font-semibold">Policy settings</h2>
          <.dm_card variant="bordered">
            <pre class="overflow-x-auto text-xs">{Jason.encode!(@observability.settings, pretty: true)}</pre>
          </.dm_card>
        </section>

        <section>
          <h2 class="mb-3 text-lg font-semibold">Feature flags</h2>
          <.dm_card variant="bordered">
            <pre class="overflow-x-auto text-xs">{Jason.encode!(@observability.flags, pretty: true)}</pre>
          </.dm_card>
        </section>

        <section>
          <h2 class="mb-3 text-lg font-semibold">Writers</h2>
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <.writer_card title="LLM LogWriter" health={@llm_writer} />
            <.writer_card title="MCP LogWriter" health={@mcp_writer} />
            <.writer_card title="MCP ToolLogWriter" health={@mcp_tool_writer} />
            <.writer_card title="Audit Writer" health={@audit_writer} />
          </div>
        </section>

        <section>
          <h2 class="mb-3 text-lg font-semibold">Runtime sink</h2>
          <.dm_card variant="bordered">
            <pre class="overflow-x-auto text-xs">{Jason.encode!(@observability.runtime_sink, pretty: true)}</pre>
          </.dm_card>
        </section>

        <section>
          <h2 class="mb-3 text-lg font-semibold">Buffers</h2>
          <div :if={map_size(@observability.buffers) == 0} class="text-sm text-on-surface-variant">
            No named buffers registered.
          </div>
          <div class="grid gap-4 md:grid-cols-2">
            <.dm_card :for={{name, health} <- @observability.buffers} variant="bordered">
              <:title>{to_string(name)}</:title>
              <pre class="overflow-x-auto text-xs">{Jason.encode!(health, pretty: true)}</pre>
            </.dm_card>
          </div>
        </section>

        <section>
          <h2 class="mb-3 text-lg font-semibold">Runtime counters (since restart)</h2>
          <div class="grid gap-4 md:grid-cols-2">
            <.dm_stat
              title="Tool calls total"
              value={to_string(get_in(@metrics, [:counters, "tool_calls_total"]) || 0)}
            />
            <.dm_stat
              title="LLM proxy accepted"
              value={to_string(get_in(@metrics, [:counters, "observability.events.accepted.llm_proxy"]) || 0)}
            />
            <.dm_stat
              title="MCP proxy accepted"
              value={to_string(get_in(@metrics, [:counters, "observability.events.accepted.mcp_proxy_root"]) || 0)}
            />
            <.dm_stat
              title="Writer drops (LLM)"
              value={to_string(get_in(@metrics, [:counters, "observability.events.dropped.llm_proxy"]) || 0)}
            />
          </div>
        </section>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :health, :map, required: true

  defp writer_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>{@title}</:title>
      <.dm_badge variant={status_variant(@health[:status])}>{@health[:status] || "unknown"}</.dm_badge>
      <dl class="mt-3 space-y-1 text-sm">
        <div><dt class="inline text-on-surface-variant">Inserted:</dt> <dd class="inline">{@health[:inserted_total] || 0}</dd></div>
        <div><dt class="inline text-on-surface-variant">Dropped:</dt> <dd class="inline">{@health[:dropped_total] || 0}</dd></div>
        <div><dt class="inline text-on-surface-variant">Failed:</dt> <dd class="inline">{@health[:failed_total] || 0}</dd></div>
      </dl>
    </.dm_card>
    """
  end

  defp status_variant(:ok), do: "success"
  defp status_variant(:unavailable), do: "error"
  defp status_variant(:disabled), do: "neutral"
  defp status_variant(_), do: "neutral"

  defp safe_call(fun, default \\ %{}) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
