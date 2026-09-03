defmodule Backplane.Admin.LogsMcpLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.LogsComponents

  alias Backplane.MCP.LogQuery

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/logs/mcp",
       loading: true,
       records: [],
       record: nil,
       tool_calls: [],
       filters: %{},
       time_range: %{since: default_since(), until: default_until()},
       cursor: nil,
       next_cursor: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :show -> load_detail(socket, params)
      _ -> load_index(socket, params)
    end
  end

  @impl true
  def handle_event("copy_text", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "copy-to-clipboard", %{text: text})}
  end

  def handle_event("load_more", _params, socket) do
    filters = socket.assigns.filters
    cursor = socket.assigns.next_cursor

    records =
      LogQuery.list(filters, %{limit: page_size(), cursor: cursor})

    last = List.last(records)
    next_cursor = if last, do: {last.inserted_at, last.id}, else: nil

    {:noreply,
     assign(socket,
       records: socket.assigns.records ++ records,
       cursor: cursor,
       next_cursor: next_cursor
     )}
  end

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <div>
      <.logs_nav current="/system/logs/mcp" />

      <div class="mb-4">
        <.link navigate={~p"/system/logs/mcp"} class="text-sm text-primary underline">
          ← Back to MCP logs
        </.link>
      </div>

      <div :if={@error}>
        <.error_state title="Record unavailable" message={@error} />
      </div>

      <div :if={@record}>
        <h1 class="mb-4 text-2xl font-bold">MCP Request Detail</h1>

        <.dm_card variant="bordered" class="mb-6">
          <h2 class="font-semibold">Root request</h2>
          <dl class="mt-3 grid gap-3 text-sm sm:grid-cols-2">
            <div><dt class="text-on-surface-variant">Operation</dt><dd>{@record.operation}</dd></div>
            <div><dt class="text-on-surface-variant">RPC method</dt><dd class="font-mono text-xs">{@record.rpc_method || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Outcome</dt><dd><.dm_badge variant={outcome_badge_variant(@record.outcome)}>{@record.outcome}</.dm_badge></dd></div>
            <div><dt class="text-on-surface-variant">Duration</dt><dd>{@record.duration_ms || "-"} ms</dd></div>
            <div><dt class="text-on-surface-variant">Protocol</dt><dd>{@record.protocol_version || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Transport</dt><dd>{@record.transport || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Session</dt><dd class="font-mono text-xs">{@record.session_id || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Auth</dt><dd>{@record.auth_kind || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Client</dt><dd>{client_label(@record)}</dd></div>
            <div><dt class="text-on-surface-variant">HTTP status</dt><dd>{@record.http_status || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Recorded</dt><dd><.local_time datetime={@record.inserted_at} /></dd></div>
            <div><dt class="text-on-surface-variant">Request ID</dt><dd><.copy_field label="Request ID" value={@record.request_id} /></dd></div>
            <div><dt class="text-on-surface-variant">Trace ID</dt><dd><.copy_field label="Trace ID" value={@record.trace_id} /></dd></div>
          </dl>

          <div :if={@record.error_message} class="mt-4">
            <h3 class="text-sm font-semibold">Error</h3>
            <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md bg-surface-container-high p-3 text-xs">{bounded_error(@record.error_message)}</pre>
          </div>

          <div class="mt-4">
            <h3 class="text-sm font-semibold">Metadata</h3>
            <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md bg-surface-container-high p-3 text-xs">{metadata_summary(@record.metadata)}</pre>
          </div>
        </.dm_card>

        <section>
          <h2 class="mb-3 text-lg font-semibold">Tool call timeline</h2>
          <div :if={@tool_calls == []} class="text-sm text-on-surface-variant">
            No child tool calls linked to this request.
          </div>
          <.dm_table :if={@tool_calls != []} id="mcp-tool-calls-table" data={@tool_calls} hover zebra>
            <:col :let={row} label="Tool">
              <span class="font-mono text-xs">{row.tool_name}</span>
            </:col>
            <:col :let={row} label="Upstream">{row.upstream_name || "-"}</:col>
            <:col :let={row} label="Outcome">
              <.dm_badge variant={outcome_badge_variant(row.outcome)} size="sm">{row.outcome}</.dm_badge>
            </:col>
            <:col :let={row} label="Duration">{row.duration_ms || "-"} ms</:col>
            <:col :let={row} label="Args hash">
              <span class="font-mono text-xs">{row.arguments_hash || "-"}</span>
            </:col>
            <:col :let={row} label="Recorded">
              <.local_time datetime={row.inserted_at} format="short" />
            </:col>
          </.dm_table>
        </section>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-2 text-2xl font-bold">MCP Logs</h1>
      <p class="mb-4 text-sm text-on-surface-variant">Persisted MCP root proxy access records.</p>

      <.logs_nav current="/system/logs/mcp" />

      <.time_range_form
        action={~p"/system/logs/mcp"}
        since={@time_range.since}
        until={@time_range.until}
        fields={[
          %{name: "rpc_method", placeholder: "RPC method", value: @filters[:rpc_method]},
          %{name: "operation", placeholder: "Operation", value: @filters[:operation]},
          %{name: "outcome", placeholder: "Outcome", value: @filters[:outcome]},
          %{name: "auth_kind", placeholder: "Auth kind", value: @filters[:auth_kind]},
          %{name: "tool_name", placeholder: "Tool name (child filter)", value: @filters[:tool_name]},
          %{name: "upstream_name", placeholder: "Upstream", value: @filters[:upstream_name]}
        ]}
      />

      <div :if={@loading}>
        <.loading_state />
      </div>

      <div :if={!@loading and @records == []}>
        <.empty_state title="No MCP logs found" message="Try widening the time range or clearing filters." />
      </div>

      <.dm_table :if={!@loading and @records != []} id="mcp-logs-table" data={@records} hover zebra>
        <:col :let={row} label="Method">
          <.link navigate={~p"/system/logs/mcp/#{row.id}"} class="font-mono text-xs text-primary underline">
            {row.rpc_method || row.operation}
          </.link>
        </:col>
        <:col :let={row} label="Operation">{row.operation}</:col>
        <:col :let={row} label="Outcome">
          <.dm_badge variant={outcome_badge_variant(row.outcome)} size="sm">{row.outcome}</.dm_badge>
        </:col>
        <:col :let={row} label="Auth">{row.auth_kind || "-"}</:col>
        <:col :let={row} label="Duration">{row.duration_ms || "-"} ms</:col>
        <:col :let={row} label="Recorded">
          <.local_time datetime={row.inserted_at} format="short" />
        </:col>
      </.dm_table>

      <div :if={@next_cursor} class="mt-4">
        <.dm_btn phx-click="load_more" size="sm">Load more</.dm_btn>
      </div>
    </div>
    """
  end

  defp load_index(socket, params) do
    filters = parse_mcp_filters(params) |> Map.drop([:tool_name, :upstream_name])
    time_range = parse_time_range(params)
    cursor = parse_cursor(params["cursor"])

    records =
      LogQuery.list(filters, %{limit: page_size(), cursor: cursor})

    last = List.last(records)
    next_cursor = if length(records) == page_size() and last, do: {last.inserted_at, last.id}

    {:noreply,
     assign(socket,
       loading: false,
       records: records,
       filters: parse_mcp_filters(params),
       time_range: time_range,
       cursor: cursor,
       next_cursor: next_cursor,
       error: nil,
       record: nil,
       tool_calls: []
     )}
  rescue
    error ->
      {:noreply,
       assign(socket,
         loading: false,
         records: [],
         error: Exception.message(error)
       )}
  end

  defp load_detail(socket, %{"id" => id}) do
    case LogQuery.get(id) do
      nil ->
        {:noreply, assign(socket, loading: false, record: nil, error: "Record not found")}

      record ->
        tool_calls =
          []
          |> maybe_append_tool_calls(record.request_id, &LogQuery.list_tool_calls_for_request/2)
          |> maybe_append_tool_calls(record.trace_id, &LogQuery.list_tool_calls_for_trace/2)
          |> Enum.uniq_by(& &1.id)

        {:noreply,
         assign(socket,
           loading: false,
           record: record,
           tool_calls: tool_calls,
           error: nil
         )}
    end
  end

  defp maybe_append_tool_calls(acc, nil, _fun), do: acc

  defp maybe_append_tool_calls(acc, id, fun) do
    acc ++ fun.(id, %{limit: 100})
  end

  defp client_label(%{client_name: name, client_version: version})
       when is_binary(name) and name != "" do
    if is_binary(version) and version != "", do: "#{name} #{version}", else: name
  end

  defp client_label(_), do: "-"
end
