defmodule Backplane.Admin.AuthAuditLive do
  use Backplane.Admin, :live_view

  alias Backplane.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/auth/audit",
       events: Auth.Audit.list_events()
     )}
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
end
