defmodule Backplane.Admin.LogsLlmLive do
  use Backplane.Admin, :live_view

  import Backplane.Admin.LogsComponents

  alias Backplane.LLM.LogQuery

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/system/logs/llm",
       loading: true,
       records: [],
       record: nil,
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
      :show ->
        load_detail(socket, params)

      _ ->
        load_index(socket, params)
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
      <.logs_nav current="/system/logs/llm" />

      <div class="mb-4">
        <.link navigate={~p"/system/logs/llm"} class="text-sm text-primary underline">
          ← Back to LLM logs
        </.link>
      </div>

      <div :if={@error}>
        <.error_state title="Record unavailable" message={@error} />
      </div>

      <div :if={@record}>
        <h1 class="mb-4 text-2xl font-bold">LLM Request Detail</h1>

        <.dm_card variant="bordered" class="mb-6">
          <dl class="grid gap-3 text-sm sm:grid-cols-2">
            <div><dt class="text-on-surface-variant">Model</dt><dd class="font-mono text-xs">{@record.requested_model || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Outcome</dt><dd><.dm_badge variant={outcome_badge_variant(@record.outcome)}>{@record.outcome}</.dm_badge></dd></div>
            <div><dt class="text-on-surface-variant">Status</dt><dd>{@record.status || "-"}</dd></div>
            <div><dt class="text-on-surface-variant">Duration</dt><dd>{@record.duration_ms || "-"} ms</dd></div>
            <div><dt class="text-on-surface-variant">Tokens</dt><dd>{token_summary(@record)}</dd></div>
            <div><dt class="text-on-surface-variant">Payload</dt><dd>{payload_status(@record)}</dd></div>
            <div><dt class="text-on-surface-variant">Recorded</dt><dd><.local_time datetime={@record.inserted_at} /></dd></div>
            <div><dt class="text-on-surface-variant">Request ID</dt><dd><.copy_field label="Request ID" value={@record.request_id} /></dd></div>
            <div><dt class="text-on-surface-variant">Trace ID</dt><dd><.copy_field label="Trace ID" value={@record.trace_id} /></dd></div>
          </dl>

          <div :if={@record.error_reason} class="mt-4">
            <h3 class="text-sm font-semibold">Error</h3>
            <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md bg-surface-container-high p-3 text-xs">{bounded_error(@record.error_reason)}</pre>
          </div>

          <div class="mt-4">
            <h3 class="text-sm font-semibold">Metadata</h3>
            <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded-md bg-surface-container-high p-3 text-xs">{metadata_summary(@record.metadata)}</pre>
          </div>
        </.dm_card>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div>
      <h1 class="mb-2 text-2xl font-bold">LLM Logs</h1>
      <p class="mb-4 text-sm text-on-surface-variant">Persisted LLM proxy access records.</p>

      <.logs_nav current="/system/logs/llm" />

      <.time_range_form
        action={~p"/system/logs/llm"}
        since={@time_range.since}
        until={@time_range.until}
        fields={[
          %{name: "model", placeholder: "Model", value: @filters[:model]},
          %{name: "outcome", placeholder: "Outcome", value: @filters[:outcome]},
          %{name: "request_id", placeholder: "Request ID", value: @filters[:request_id]},
          %{name: "trace_id", placeholder: "Trace ID", value: @filters[:trace_id]}
        ]}
      />

      <div :if={@loading}>
        <.loading_state />
      </div>

      <div :if={!@loading and @records == []}>
        <.empty_state title="No LLM logs found" message="Try widening the time range or clearing filters." />
      </div>

      <.dm_table :if={!@loading and @records != []} id="llm-logs-table" data={@records} hover zebra>
        <:col :let={row} label="Model">
          <.link navigate={~p"/system/logs/llm/#{row.id}"} class="font-mono text-xs text-primary underline">
            {row.requested_model || "-"}
          </.link>
        </:col>
        <:col :let={row} label="Outcome">
          <.dm_badge variant={outcome_badge_variant(row.outcome)} size="sm">{row.outcome}</.dm_badge>
        </:col>
        <:col :let={row} label="Status">{row.status || "-"}</:col>
        <:col :let={row} label="Latency">{row.duration_ms || "-"} ms</:col>
        <:col :let={row} label="Tokens">{token_summary(row)}</:col>
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
    filters = parse_llm_filters(params)
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
       filters: filters,
       time_range: time_range,
       cursor: cursor,
       next_cursor: next_cursor,
       error: nil,
       record: nil
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
        {:noreply, assign(socket, loading: false, record: record, error: nil)}
    end
  end

  defp token_summary(%{input_tokens: in_t, output_tokens: out_t}) do
    in_val = in_t || 0
    out_val = out_t || 0
    "#{in_val} / #{out_val}"
  end
end
