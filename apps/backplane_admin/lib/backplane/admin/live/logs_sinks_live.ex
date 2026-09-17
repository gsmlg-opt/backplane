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
        Writer queue health and runtime sink status. Historical usage is available on the logs pages.
      </p>

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
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            <.writer_card title="LLM LogWriter" health={@llm_writer} />
            <.mcp_writer_card health={aggregate_mcp_health(@mcp_writer, @mcp_tool_writer)} />
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

  attr(:title, :string, required: true)
  attr(:health, :map, required: true)

  defp writer_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>{@title}</:title>
      <.dm_badge variant={status_variant(@health[:status])}>{@health[:status] || "unknown"}</.dm_badge>
      <dl class="mt-3 space-y-1 text-sm">
        <div><dt class="inline text-on-surface-variant">Inserted:</dt> <dd class="inline">{format_number(@health[:inserted_total])}</dd></div>
        <div><dt class="inline text-on-surface-variant">Dropped:</dt> <dd class="inline">{format_number(@health[:dropped_total])}</dd></div>
        <div><dt class="inline text-on-surface-variant">Failed:</dt> <dd class="inline">{format_number(@health[:failed_total])}</dd></div>
      </dl>
    </.dm_card>
    """
  end

  attr(:health, :map, required: true)

  defp mcp_writer_card(assigns) do
    ~H"""
    <.dm_card variant="bordered">
      <:title>MCP LogWriter</:title>
      <.dm_badge variant={status_variant(@health.status)}>{status_label(@health.status)}</.dm_badge>
      <dl class="mt-3 grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
        <div><dt class="inline text-on-surface-variant">Inserted records:</dt> <dd class="inline">{format_number(@health.inserted_total)}</dd></div>
        <div><dt class="inline text-on-surface-variant">Dropped:</dt> <dd class="inline">{format_number(@health.dropped_total)}</dd></div>
        <div><dt class="inline text-on-surface-variant">Failed:</dt> <dd class="inline">{format_number(@health.failed_total)}</dd></div>
        <div><dt class="inline text-on-surface-variant">Duplicates:</dt> <dd class="inline">{format_number(@health.duplicate_total)}</dd></div>
      </dl>
      <div class="mt-3 space-y-2 border-t border-outline-variant pt-3 text-xs">
        <.mcp_channel_row label="Request records" health={@health.root} />
        <.mcp_channel_row label="Tool calls" health={@health.tools} />
      </div>
    </.dm_card>
    """
  end

  attr(:label, :string, required: true)
  attr(:health, :map, required: true)

  defp mcp_channel_row(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
      <span class="font-medium">{@label}</span>
      <.dm_badge variant={status_variant(@health.status)}>{status_label(@health.status)}</.dm_badge>
      <span class="text-on-surface-variant">queue {format_number(@health.queue.queued)}/{format_number(@health.queue.capacity)}</span>
      <span class="text-on-surface-variant">inserted {format_number(@health.inserted_total)}</span>
      <span :if={@health.dropped_total > 0} class="text-on-surface-variant">dropped {format_number(@health.dropped_total)}</span>
      <span :if={@health.failed_total > 0} class="text-error">failed {format_number(@health.failed_total)}</span>
      <span :if={@health.duplicate_total > 0} class="text-on-surface-variant">duplicates {format_number(@health.duplicate_total)}</span>
    </div>
    """
  end

  @doc false
  def aggregate_mcp_health(root_health, tool_health) do
    root = normalize_mcp_channel(root_health)
    tools = normalize_mcp_channel(tool_health)

    %{
      status: aggregate_status(root.status, tools.status),
      inserted_total: root.inserted_total + tools.inserted_total,
      dropped_total: root.dropped_total + tools.dropped_total,
      failed_total: root.failed_total + tools.failed_total,
      duplicate_total: root.duplicate_total + tools.duplicate_total,
      root: root,
      tools: tools
    }
  end

  defp normalize_mcp_channel(health) when is_map(health) do
    buffer = Map.get(health, :buffer)
    writer_status = Map.get(health, :status)

    %{
      status: channel_status(writer_status, buffer),
      queue: %{
        queued: number(Map.get(buffer || %{}, :queued)),
        capacity: number(Map.get(buffer || %{}, :capacity))
      },
      inserted_total: number(Map.get(health, :inserted_total)),
      dropped_total: number(Map.get(health, :dropped_total)),
      failed_total: number(Map.get(health, :failed_total)),
      duplicate_total: number(Map.get(health, :duplicate_total))
    }
  end

  defp normalize_mcp_channel(_), do: normalize_mcp_channel(%{})

  defp channel_status(:disabled, _buffer), do: :disabled

  defp channel_status(:ok, %{status: :ok}), do: :ok
  defp channel_status(:ok, _buffer), do: :unavailable
  defp channel_status(_, _buffer), do: :unavailable

  defp aggregate_status(:ok, :ok), do: :ok
  defp aggregate_status(:disabled, :disabled), do: :disabled
  defp aggregate_status(:unavailable, _), do: :unavailable
  defp aggregate_status(_, :unavailable), do: :unavailable
  defp aggregate_status(_, _), do: :degraded

  defp number(value) when is_integer(value) and value >= 0, do: value
  defp number(_value), do: 0

  defp format_number(value) do
    value
    |> number()
    |> Integer.to_string()
    |> then(&Regex.replace(~r/\B(?=(\d{3})+(?!\d))/, &1, ","))
  end

  defp status_variant(:ok), do: "success"
  defp status_variant(:unavailable), do: "error"
  defp status_variant(:degraded), do: "neutral"
  defp status_variant(:disabled), do: "neutral"
  defp status_variant(_), do: "neutral"

  defp status_label(:degraded), do: "degraded"
  defp status_label(status), do: to_string(status || :unavailable)

  defp safe_call(fun, default \\ %{}) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
