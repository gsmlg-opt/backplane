defmodule Backplane.Admin.AuthAuditLive do
  use Backplane.Admin, :live_view

  alias Backplane.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/auth/audit",
       events: [],
       filters: empty_filters()
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = audit_filters(params)

    {:noreply,
     socket
     |> assign(current_path: URI.parse(uri).path, filters: filters)
     |> assign(events: Auth.Audit.list_events(filters))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <h1 class="text-2xl font-bold">Auth Audit</h1>
        <p class="mt-1 text-sm text-on-surface-variant">
          Persisted security events from the Backplane Auth provider.
        </p>
      </div>

      <.dm_card variant="bordered">
        <:title>Audit Events</:title>

        <form
          id="auth-audit-filter-form"
          method="get"
          action="/auth/audit"
          class="mb-4 grid gap-3 md:grid-cols-4"
        >
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="event_type"
            placeholder="Event type"
            value={@filters["event_type"]}
          />
          <select
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="severity"
          >
            <option value="" selected={@filters["severity"] == ""}>All severities</option>
            <option value="info" selected={@filters["severity"] == "info"}>info</option>
            <option value="warning" selected={@filters["severity"] == "warning"}>warning</option>
            <option value="error" selected={@filters["severity"] == "error"}>error</option>
          </select>
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="target_type"
            placeholder="Target type"
            value={@filters["target_type"]}
          />
          <div class="flex gap-2">
            <input
              class="min-w-0 flex-1 rounded-md border border-outline bg-surface px-3 py-2 text-sm"
              name="search"
              placeholder="Search ids"
              value={@filters["search"]}
            />
            <.dm_btn type="submit" variant="primary" size="sm">Filter</.dm_btn>
          </div>
        </form>

        <div :if={@events == []} class="py-8 text-center text-on-surface-variant">
          No Auth audit events recorded.
        </div>

        <.dm_table :if={@events != []} id="auth-audit-table" data={@events} hover zebra>
          <:col :let={event} label="Event">
            <div class="font-medium">{event.event_type}</div>
            <code class="text-xs text-on-surface-variant">{event.id}</code>
          </:col>
          <:col :let={event} label="Severity">
            <.dm_badge variant={severity_variant(event.severity)}>{event.severity}</.dm_badge>
          </:col>
          <:col :let={event} label="Actor">
            <span class="text-sm">{actor_label(event)}</span>
          </:col>
          <:col :let={event} label="Target">
            <span class="text-sm">{target_label(event)}</span>
          </:col>
          <:col :let={event} label="Metadata">
            <span class="text-sm text-on-surface-variant">{metadata_summary(event.metadata)}</span>
          </:col>
          <:col :let={event} label="Recorded">
            <span class="text-sm text-on-surface-variant">{format_datetime(event.inserted_at)}</span>
          </:col>
        </.dm_table>
      </.dm_card>
    </div>
    """
  end

  defp actor_label(%{actor_type: nil}), do: "system"
  defp actor_label(%{actor_type: type, actor_id: nil}), do: type
  defp actor_label(%{actor_type: type, actor_id: id}), do: "#{type}:#{id}"

  defp target_label(%{target_type: nil}), do: "none"
  defp target_label(%{target_type: type, target_id: nil}), do: type
  defp target_label(%{target_type: type, target_id: id}), do: "#{type}:#{id}"

  defp metadata_summary(metadata) when metadata == %{}, do: "none"

  defp metadata_summary(metadata) when is_map(metadata) do
    metadata
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end

  defp metadata_summary(_metadata), do: "none"

  defp severity_variant("error"), do: "error"
  defp severity_variant("warning"), do: "warning"
  defp severity_variant("info"), do: "info"
  defp severity_variant(_severity), do: "neutral"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")

  defp audit_filters(params) do
    empty_filters()
    |> Map.merge(Map.take(params, ["event_type", "severity", "target_type", "search"]))
    |> Map.new(fn {key, value} -> {key, String.trim(to_string(value || ""))} end)
  end

  defp empty_filters do
    %{
      "event_type" => "",
      "severity" => "",
      "target_type" => "",
      "search" => ""
    }
  end
end
