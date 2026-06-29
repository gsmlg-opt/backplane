defmodule Backplane.Admin.AuthAuditLive do
  use Backplane.Admin, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/auth/audit",
       events: audit_event_groups()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">Auth Audit</h1>
        <p class="mt-1 text-sm text-on-surface-variant">
          Security-relevant Auth events for OAuth, RBAC, providers, clients, and tokens.
        </p>
      </div>

      <.dm_card variant="bordered">
        <:title>Event Streams</:title>
        <div class="grid gap-4 lg:grid-cols-2">
          <div :for={event <- @events} class="rounded-md border border-outline-variant p-4">
            <div class="text-sm font-medium">{event.title}</div>
            <p class="mt-1 text-sm text-on-surface-variant">{event.body}</p>
          </div>
        </div>
      </.dm_card>

      <.dm_card variant="bordered">
        <:title>Storage Status</:title>
        <p class="text-sm text-on-surface-variant">
          Persistent Auth audit storage is not implemented yet. This page defines the
          operator-facing event categories before the audit event table lands.
        </p>
      </.dm_card>
    </div>
    """
  end

  defp audit_event_groups do
    [
      %{
        title: "Login events",
        body:
          "Track upstream provider login attempts, successes, failures, and linked identities."
      },
      %{
        title: "Token events",
        body:
          "Track authorization code issuance, token exchange, refresh, revocation, and reuse detection."
      },
      %{
        title: "Client events",
        body:
          "Track dynamic client registrations, client disablement, and token revocation by client."
      },
      %{
        title: "Role events",
        body: "Track role creation, scope changes, user assignment, and assignment removal."
      }
    ]
  end
end
