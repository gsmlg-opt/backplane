defmodule Backplane.Admin.AuthRbacLive do
  use Backplane.Admin, :live_view

  alias Backplane.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       assignments: [],
       current_path: "/auth/rbac/users",
       effective_scopes_by_user_id: %{},
       page: page(:users),
       roles: [],
       users: []
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    action = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(current_path: URI.parse(uri).path, page: page(action))
     |> assign_action_data(action)}
  end

  @impl true
  def handle_event("create-user", %{"user" => params}, socket) do
    with {:ok, user} <- Auth.Accounts.create_user(user_attrs(params)),
         {:ok, _credential} <- maybe_set_password(user, Map.get(params, "password")) do
      Auth.Audit.record(
        "user.created",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{target_type: "auth_user", target_id: user.id, metadata: %{"email" => user.email}}
      )

      {:noreply,
       socket
       |> put_flash(:info, "Auth user created.")
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Auth user could not be created.")}
    end
  end

  def handle_event("disable-user", %{"id" => id}, socket) do
    with %{email: email} = user <- Auth.Accounts.get_user(id),
         {:ok, _user} <- Auth.Accounts.disable_user(user) do
      Auth.Audit.record(
        "user.disabled",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{
          target_type: "auth_user",
          target_id: id,
          metadata: %{"email" => email}
        }
      )

      {:noreply,
       socket
       |> put_flash(:info, "Auth user disabled.")
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Auth user was not found.")}
    end
  end

  def handle_event("create-role", %{"role" => params}, socket) do
    with {:ok, role} <- Auth.RBAC.create_role(role_attrs(params)),
         {:ok, _role_scope} <- maybe_assign_role_scope(role, Map.get(params, "scope")) do
      Auth.Audit.record(
        "role.created",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{target_type: "auth_role", target_id: role.id, metadata: %{"role" => role.name}}
      )

      {:noreply,
       socket
       |> put_flash(:info, "RBAC role created.")
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "RBAC role could not be created.")}
    end
  end

  def handle_event("assign-role", %{"assignment" => params}, socket) do
    with user when not is_nil(user) <- Auth.Accounts.get_user(Map.get(params, "user_id", "")),
         role when not is_nil(role) <- get_role_by_id(Map.get(params, "role_id", "")),
         {:ok, _user_role} <- Auth.RBAC.assign_user_role(user, role) do
      Auth.Audit.record(
        "role.assigned",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{
          target_type: "auth_user",
          target_id: user.id,
          metadata: %{"role" => role.name, "email" => user.email}
        }
      )

      {:noreply,
       socket
       |> put_flash(:info, "RBAC role assigned.")
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "RBAC role could not be assigned.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <h1 class="text-2xl font-bold">{@page.title}</h1>
        <p class="mt-1 text-sm text-on-surface-variant">{@page.description}</p>
      </div>

      <.dm_card :if={@live_action == :users} variant="bordered">
        <:title>Users</:title>
        <form id="auth-user-form" phx-submit="create-user" class="mb-4 grid gap-3 lg:grid-cols-4">
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="user[email]"
            placeholder="email@example.com"
            required
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="user[name]"
            placeholder="Display name"
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="user[password]"
            placeholder="Initial password"
            type="password"
          />
          <div>
            <.dm_btn type="submit" variant="primary" size="sm">Create User</.dm_btn>
          </div>
        </form>

        <div :if={@users == []} class="py-8 text-center text-on-surface-variant">
          No local Auth users.
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
          <:col :let={user} label="Last Login">
            <span class="text-sm text-on-surface-variant">{format_datetime(user.last_login_at)}</span>
          </:col>
          <:col :let={user} label="Actions">
            <.dm_btn
              :if={user.active}
              type="button"
              variant="error"
              size="xs"
              phx-click="disable-user"
              phx-value-id={user.id}
              data-confirm={"Disable Auth user #{user.email}?"}
            >
              Disable
            </.dm_btn>
            <span :if={!user.active} class="text-sm text-on-surface-variant">Inactive</span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :roles} variant="bordered">
        <:title>Roles</:title>
        <form id="auth-role-form" phx-submit="create-role" class="mb-4 grid gap-3 lg:grid-cols-4">
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="role[name]"
            placeholder="role-name"
            required
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="role[label]"
            placeholder="Label"
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="role[scope]"
            placeholder="optional: scope:name"
          />
          <div>
            <.dm_btn type="submit" variant="primary" size="sm">Create Role</.dm_btn>
          </div>
        </form>

        <div :if={@roles == []} class="py-8 text-center text-on-surface-variant">
          No RBAC roles configured.
        </div>

        <.dm_table :if={@roles != []} id="auth-role-table" data={@roles} hover zebra>
          <:col :let={role} label="Role">
            <div class="font-medium">{role.label || role.name}</div>
            <code class="text-xs text-on-surface-variant">{role.name}</code>
          </:col>
          <:col :let={role} label="Type">
            <.dm_badge variant={if role.system, do: "info", else: "neutral"}>
              {if role.system, do: "System", else: "Custom"}
            </.dm_badge>
          </:col>
          <:col :let={role} label="Scopes">
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={scope <- role_scope_names(role)} variant="neutral" size="sm">
                {scope}
              </.dm_badge>
              <span :if={role_scope_names(role) == []} class="text-sm text-on-surface-variant">
                None
              </span>
            </div>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :assignments} variant="bordered">
        <:title>Assignments</:title>
        <form
          id="auth-assignment-form"
          phx-submit="assign-role"
          class="mb-4 grid gap-3 md:grid-cols-3"
        >
          <select
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="assignment[user_id]"
            required
          >
            <option value="">Select user</option>
            <option :for={user <- @users} value={user.id}>{user.email}</option>
          </select>
          <select
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="assignment[role_id]"
            required
          >
            <option value="">Select role</option>
            <option :for={role <- @roles} value={role.id}>{role.label || role.name}</option>
          </select>
          <div>
            <.dm_btn type="submit" variant="primary" size="sm">Assign Role</.dm_btn>
          </div>
        </form>

        <div :if={@assignments == []} class="py-8 text-center text-on-surface-variant">
          No role assignments configured.
        </div>

        <.dm_table :if={@assignments != []} id="auth-assignment-table" data={@assignments} hover zebra>
          <:col :let={assignment} label="User">
            <div class="font-medium">{assignment.user.name || assignment.user.email}</div>
            <code class="text-xs text-on-surface-variant">{assignment.user.email}</code>
          </:col>
          <:col :let={assignment} label="Role">
            <div class="font-medium">{assignment.role.label || assignment.role.name}</div>
            <code class="text-xs text-on-surface-variant">{assignment.role.name}</code>
          </:col>
          <:col :let={assignment} label="Role Scopes">
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={scope <- role_scope_names(assignment.role)} variant="neutral" size="sm">
                {scope}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={assignment} label="Effective Scopes">
            <div class="flex flex-wrap gap-1">
              <.dm_badge
                :for={scope <- Map.get(@effective_scopes_by_user_id, assignment.user.id, [])}
                variant="secondary"
                size="sm"
              >
                {scope}
              </.dm_badge>
            </div>
          </:col>
        </.dm_table>
      </.dm_card>
    </div>
    """
  end

  defp assign_action_data(socket, :users) do
    assign(socket,
      assignments: [],
      effective_scopes_by_user_id: %{},
      roles: [],
      users: Auth.Accounts.list_users()
    )
  end

  defp assign_action_data(socket, :roles) do
    assign(socket,
      assignments: [],
      effective_scopes_by_user_id: %{},
      roles: Auth.RBAC.list_roles(),
      users: []
    )
  end

  defp assign_action_data(socket, :assignments) do
    assignments = Auth.RBAC.list_user_roles()

    assign(socket,
      assignments: assignments,
      effective_scopes_by_user_id: effective_scopes_by_user_id(assignments),
      roles: Auth.RBAC.list_roles(),
      users: Auth.Accounts.list_users()
    )
  end

  defp page(:users) do
    %{
      title: "RBAC Users",
      description: "Local Backplane Auth users who can authorize first-party OAuth clients."
    }
  end

  defp page(:roles) do
    %{
      title: "RBAC Roles",
      description: "Role definitions and the OAuth scopes they grant."
    }
  end

  defp page(:assignments) do
    %{
      title: "Role Assignments",
      description: "User-to-role bindings with effective OAuth scope previews."
    }
  end

  defp effective_scopes_by_user_id(assignments) do
    assignments
    |> Enum.map(& &1.user)
    |> Enum.uniq_by(& &1.id)
    |> Map.new(fn user -> {user.id, Auth.RBAC.effective_scope_names(user)} end)
  end

  defp role_scope_names(role) do
    role.role_scopes
    |> Enum.map(& &1.scope_name)
    |> Enum.sort()
  end

  defp user_attrs(params) do
    %{
      email: Map.get(params, "email"),
      name: Map.get(params, "name")
    }
  end

  defp role_attrs(params) do
    %{
      name: Map.get(params, "name"),
      label: Map.get(params, "label")
    }
  end

  defp maybe_set_password(user, password) when is_binary(password) and password != "" do
    Auth.Accounts.set_password(user, password)
  end

  defp maybe_set_password(_user, _password), do: {:ok, :no_password}

  defp maybe_assign_role_scope(role, scope) when is_binary(scope) and scope != "" do
    Auth.RBAC.assign_role_scope(role, scope)
  end

  defp maybe_assign_role_scope(_role, _scope), do: {:ok, :no_scope}

  defp get_role_by_id(id) when is_binary(id) do
    Auth.RBAC.list_roles()
    |> Enum.find(&(&1.id == id))
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
