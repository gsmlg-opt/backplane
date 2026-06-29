defmodule Backplane.Admin.AuthRbacLive do
  use Backplane.Admin, :live_view

  alias Backplane.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/auth/rbac/users",
       bootstrap_admin_emails: [],
       users: [],
       page: page(:users)
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    action = socket.assigns.live_action

    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       bootstrap_admin_emails: bootstrap_admin_emails(action),
       users: users(action),
       page: page(action)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div>
        <h1 class="text-2xl font-bold">{@page.title}</h1>
        <p class="mt-1 text-sm text-on-surface-variant">{@page.description}</p>
      </div>

      <.dm_card :if={@live_action == :users} variant="bordered">
        <:title>Bootstrap Admins</:title>
        <div :if={@bootstrap_admin_emails == []} class="text-sm text-on-surface-variant">
          No bootstrap admin emails configured.
        </div>
        <div :if={@bootstrap_admin_emails != []} class="flex flex-wrap gap-2">
          <.dm_badge :for={email <- @bootstrap_admin_emails} variant="info">
            {email}
          </.dm_badge>
        </div>
      </.dm_card>

      <.dm_card :if={@live_action == :users} variant="bordered">
        <:title>Users</:title>
        <div :if={@users == []} class="py-8 text-center text-on-surface-variant">
          No users have signed in.
        </div>

        <.dm_table :if={@users != []} id="auth-user-table" data={@users} hover zebra>
          <:col :let={user} label="User">
            <div class="font-medium">{user.name || user.email}</div>
            <code class="text-xs text-on-surface-variant">{user.email}</code>
          </:col>
          <:col :let={user} label="Status">
            <.dm_badge variant={if user.active, do: "success", else: "error"}>
              {if user.active, do: "Active", else: "Inactive"}
            </.dm_badge>
          </:col>
          <:col :let={user} label="Access">
            <.dm_badge variant={if Accounts.bootstrap_admin?(user), do: "info", else: "neutral"}>
              {if Accounts.bootstrap_admin?(user), do: "Bootstrap Admin", else: "Member"}
            </.dm_badge>
          </:col>
          <:col :let={user} label="Last Login">
            <span class="text-sm text-on-surface-variant">{format_datetime(user.last_login_at)}</span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action != :users} variant="bordered">
        <:title>{@page.card_title}</:title>
        <div class="grid gap-4 lg:grid-cols-2">
          <div :for={item <- @page.items} class="rounded-md border border-outline-variant p-4">
            <div class="text-sm font-medium">{item.title}</div>
            <p class="mt-1 text-sm text-on-surface-variant">{item.body}</p>
          </div>
        </div>
      </.dm_card>
    </div>
    """
  end

  defp bootstrap_admin_emails(:users), do: Accounts.bootstrap_admin_emails()
  defp bootstrap_admin_emails(_action), do: []

  defp users(:users), do: Accounts.list_users()
  defp users(_action), do: []

  defp page(:users) do
    %{
      title: "RBAC Users",
      description: "Human users provisioned from inbound identity providers."
    }
  end

  defp page(:roles) do
    %{
      title: "RBAC Roles",
      description: "Runtime role definitions and their Backplane scope bundles.",
      card_title: "Role Management",
      items: [
        %{
          title: "Built-in Roles",
          body: "Admin, member, and viewer roles should be seeded and protected from deletion."
        },
        %{
          title: "Scope Bundles",
          body: "Each role maps to tool scopes such as *, prefix::*, prefix::tool, and system::*."
        }
      ]
    }
  end

  defp page(:assignments) do
    %{
      title: "Role Assignments",
      description: "User-to-role assignments and effective scope preview.",
      card_title: "Assignment Management",
      items: [
        %{
          title: "User Roles",
          body: "Operators assign roles to provisioned users after identity linking."
        },
        %{
          title: "Effective Scopes",
          body:
            "The UI should preview the final scope set that will be injected into future OAuth tokens."
        }
      ]
    }
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
