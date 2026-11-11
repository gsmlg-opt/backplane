defmodule Backplane.Admin.AuthOAuthLive do
  use Backplane.Admin, :live_view

  alias Backplane.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       client_secret: nil,
       clients: [],
       current_path: "/auth/overview",
       editing_client: nil,
       issuer: nil,
       overview_stats: [],
       page: page(:overview),
       provider_metadata: [],
       scopes: [],
       sessions: [],
       tokens: [],
       users_by_id: %{}
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    action = socket.assigns.live_action

    socket =
      socket
      |> assign(current_path: URI.parse(uri).path, issuer: oauth_issuer(), page: page(action))
      |> assign_action_data(action)

    case editing_client(action, params) do
      {:ok, editing_client} ->
        {:noreply,
         assign(socket,
           client_secret: if(action == :client_edit, do: nil, else: socket.assigns.client_secret),
           editing_client: editing_client
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, dgettext("user", "OAuth client was not found."))
         |> push_navigate(to: ~p"/auth/oauth/clients")}
    end
  end

  @impl true
  def handle_event("create-client", %{"client" => params}, socket) do
    case Auth.OAuth.create_client(client_attrs(params)) do
      {:ok, %{client: client, secret: secret}} ->
        Backplane.Admin.Audit.record("oauth_client.create", "oauth_client", client.id)

        Auth.Audit.record(
          "client.created",
          %{actor_type: "admin_ui", actor_id: "backplane_admin"},
          %{
            target_type: "oauth_client",
            target_id: client.id,
            metadata: %{"client_name" => client.name}
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "OAuth client created."))
         |> assign(:client_secret, %{client_id: client.id, name: client.name, secret: secret})
         |> assign_action_data(socket.assigns.live_action)}

      {:ok, client} ->
        Backplane.Admin.Audit.record("oauth_client.create", "oauth_client", client.id)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "OAuth client created."))
         |> assign(:client_secret, nil)
         |> assign_action_data(socket.assigns.live_action)}

      {:error, :https_required} ->
        {:noreply, put_flash(socket, :error, https_required_message())}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("user", "OAuth client could not be created."))}
    end
  end

  def handle_event(
        "update-client-resources",
        %{"client" => params},
        %{assigns: %{editing_client: client}} = socket
      )
      when not is_nil(client) do
    resources = selected_resources(Map.get(params, "resources"))

    case Auth.OAuth.update_client_resources(client, resources) do
      {:ok, updated} ->
        Backplane.Admin.Audit.record("oauth_client.update_resources", "oauth_client", updated.id)

        Auth.Audit.record(
          "client.resources_updated",
          admin_actor(),
          %{
            target_type: "oauth_client",
            target_id: updated.id,
            metadata: %{
              "resources" => Enum.map(Auth.OAuth.client_resources(updated), &to_string/1)
            }
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "OAuth client resources updated."))
         |> assign(:editing_client, updated)}

      {:error, :https_required} ->
        {:noreply, put_flash(socket, :error, https_required_message())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, dgettext("user", "OAuth client resources could not be updated."))}
    end
  end

  def handle_event("disable-client", %{"id" => id}, socket) do
    with %{name: name} = client <- Auth.OAuth.get_client(id),
         {:ok, _client} <- Auth.OAuth.disable_client(client) do
      Backplane.Admin.Audit.record("oauth_client.disable", "oauth_client", client.id)

      Auth.Audit.record(
        "client.disabled",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{
          target_type: "oauth_client",
          target_id: id,
          metadata: %{"client_name" => name}
        }
      )

      {:noreply,
       socket
       |> put_flash(:info, dgettext("user", "OAuth client disabled."))
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, dgettext("user", "OAuth client was not found."))}
    end
  end

  def handle_event("rotate-client-secret", %{"id" => id}, socket) do
    with %{name: name} = client <- Auth.OAuth.get_client(id),
         {:ok, %{client: rotated, secret: secret}} <- Auth.OAuth.rotate_client_secret(client) do
      Backplane.Admin.Audit.record("oauth_client.rotate_secret", "oauth_client", rotated.id)

      Auth.Audit.record(
        "client.secret_rotated",
        %{actor_type: "admin_ui", actor_id: "backplane_admin"},
        %{
          target_type: "oauth_client",
          target_id: id,
          metadata: %{"client_name" => name}
        }
      )

      {:noreply,
       socket
       |> put_flash(:info, dgettext("user", "OAuth client secret rotated."))
       |> assign(:client_secret, %{client_id: rotated.id, name: rotated.name, secret: secret})
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, dgettext("user", "OAuth client secret could not be rotated."))}
    end
  end

  def handle_event("create-scope", %{"scope" => params}, socket) do
    case Auth.OAuth.create_scope(scope_attrs(params)) do
      {:ok, scope} ->
        Backplane.Admin.Audit.record("oauth_scope.create", "oauth_scope", scope.id)

        Auth.Audit.record(
          "scope.created",
          %{actor_type: "admin_ui", actor_id: "backplane_admin"},
          %{
            target_type: "oauth_scope",
            target_id: scope.id,
            metadata: %{"scope" => scope.name}
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "OAuth scope created."))
         |> assign_action_data(socket.assigns.live_action)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, dgettext("user", "OAuth scope could not be created."))}
    end
  end

  def handle_event("revoke-token", %{"id" => id}, socket) do
    case Auth.Tokens.revoke_token_by_id(id) do
      {:ok, _token} ->
        Backplane.Admin.Audit.record("oauth_token.revoke", "oauth_token", id)

        Auth.Audit.record(
          "token.revoked",
          %{actor_type: "admin_ui", actor_id: "backplane_admin"},
          %{
            target_type: "oauth_token",
            target_id: id
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "OAuth token revoked."))
         |> assign_action_data(socket.assigns.live_action)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, dgettext("user", "OAuth token was not found."))}
    end
  end

  def handle_event("revoke-session", %{"id" => id}, socket) do
    case Auth.Accounts.revoke_session_by_id(id, admin_actor()) do
      {:ok, _session} ->
        Backplane.Admin.Audit.record("auth_session.revoke", "auth_session", id)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("user", "Auth session revoked."))
         |> assign_action_data(socket.assigns.live_action)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, dgettext("user", "Auth session was not found."))}
    end
  end

  defp https_required_message,
    do: dgettext("user", "OAuth protected resources require an HTTPS API origin.")

  defp admin_actor, do: %{actor_type: "admin_ui", actor_id: "backplane_admin"}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <h1 class="text-2xl font-bold">{@page.title}</h1>
        <p class="mt-1 text-sm text-on-surface-variant">{@page.description}</p>
      </div>

      <.dm_card variant="bordered">
        <:title>{dgettext("user", "Authorization Server")}</:title>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">{dgettext("admin", "Issuer")}</div>
            <code class="mt-1 block break-all text-sm">{@issuer}</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">{dgettext("admin", "Authorize")}</div>
            <code class="mt-1 block break-all text-sm">/oauth/authorize</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">{dgettext("admin", "Token")}</div>
            <code class="mt-1 block break-all text-sm">/oauth/token</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">{dgettext("admin", "JWKS")}</div>
            <code class="mt-1 block break-all text-sm">/oauth/jwks</code>
          </div>
        </div>
      </.dm_card>

      <.dm_card :if={@live_action == :overview} variant="bordered">
        <:title>{dgettext("user", "Auth Inventory")}</:title>
        <div class="grid gap-3 md:grid-cols-4">
          <div
            :for={stat <- @overview_stats}
            class="rounded-md border border-outline-variant p-3"
          >
            <div class="text-xs font-medium uppercase text-on-surface-variant">{stat.label}</div>
            <div class="mt-1 text-2xl font-semibold">{stat.value}</div>
            <div class="mt-1 text-xs text-on-surface-variant">{stat.note}</div>
          </div>
        </div>
      </.dm_card>

      <.dm_card :if={@live_action == :providers} variant="bordered">
        <:title>{dgettext("user", "Backplane OAuth Provider")}</:title>
        <.dm_table id="auth-provider-metadata-table" data={@provider_metadata} hover zebra>
          <:col :let={item} label={dgettext("user", "Capability")}>
            <div class="font-medium">{item.name}</div>
          </:col>
          <:col :let={item} label={dgettext("common", "Value")}>
            <code class="break-all text-xs text-on-surface-variant">{item.value}</code>
          </:col>
          <:col :let={item} label={dgettext("common", "Status")}>
            <.dm_badge variant={item.variant}>{item.status}</.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :clients} variant="bordered">
        <:title>{dgettext("user", "Registered Clients")}</:title>
        <form id="oauth-client-form" phx-submit="create-client" class="mb-4 grid gap-3 lg:grid-cols-5">
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="client[name]"
            placeholder={dgettext("user", "Client name")}
            required
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm lg:col-span-2"
            name="client[redirect_uris]"
            placeholder="https://app.example.com/auth/callback"
            required
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="client[scopes]"
            placeholder="openid profile email"
          />
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="client[confidential]" value="false" />
            <input type="checkbox" name="client[confidential]" value="true" checked />
            {dgettext("user", "Confidential")}
          </label>
          <div class="flex flex-wrap gap-4 lg:col-span-5">
            <.dm_checkbox
              id="oauth-client-resource-mcp"
              name="client[resources][mcp]"
              label={dgettext("admin", "MCP (/mcp)")}
              value="true"
              checked={false}
            />
            <.dm_checkbox
              id="oauth-client-resource-v1"
              name="client[resources][v1]"
              label={dgettext("admin", "LLM API (/v1)")}
              value="true"
              checked={false}
            />
          </div>
          <div class="lg:col-span-5">
            <.dm_btn type="submit" variant="primary" size="sm">{dgettext("user", "Create Client")}</.dm_btn>
          </div>
        </form>

        <div
          :if={@client_secret}
          class="mb-4 rounded-md border border-outline-variant bg-surface-container-high p-3"
        >
          <div class="text-sm font-medium">{dgettext("user", "Client secret for %{name}", name: @client_secret.name)}</div>
          <code class="mt-1 block break-all text-sm">{@client_secret.secret}</code>
        </div>

        <div :if={@clients == []} class="py-8 text-center text-on-surface-variant">
          {dgettext("user", "No OAuth clients registered.")}
        </div>

        <.dm_table :if={@clients != []} id="oauth-client-table" data={@clients} hover zebra>
          <:col :let={client} label={dgettext("user", "Client")}>
            <div class="font-medium">{client.name}</div>
            <code class="text-xs text-on-surface-variant">{client.id}</code>
          </:col>
          <:col :let={client} label={dgettext("common", "Type")}>
            <div class="flex flex-wrap gap-1">
              <.dm_badge variant={if client.confidential, do: "info", else: "secondary"}>
                {if client.confidential,
                  do: dgettext("user", "Confidential"),
                  else: dgettext("user", "Public")}
              </.dm_badge>
              <.dm_badge :if={client.pkce} variant="success">{dgettext("admin", "PKCE")}</.dm_badge>
            </div>
          </:col>
          <:col :let={client} label={dgettext("common", "Status")}>
            <.dm_badge variant={if client_disabled?(client), do: "error", else: "success"}>
              {if client_disabled?(client),
                do: dgettext("common", "Disabled"),
                else: dgettext("common", "Enabled")}
            </.dm_badge>
          </:col>
          <:col :let={client} label={dgettext("user", "Redirect URIs")}>
            <div class="space-y-1">
              <code
                :for={uri <- client.redirect_uris}
                class="block break-all text-xs text-on-surface-variant"
              >
                {uri}
              </code>
            </div>
          </:col>
          <:col :let={client} label={dgettext("user", "Scopes")}>
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={scope <- scope_names(client.authorized_scopes)} variant="neutral" size="sm">
                {scope}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={client} label={dgettext("user", "Resources")}>
            <div class="flex flex-wrap gap-1">
              <.dm_badge
                :for={resource <- Auth.OAuth.client_resources(client)}
                variant={resource_variant(resource)}
                size="sm"
              >
                {resource_label(resource)}
              </.dm_badge>
              <.dm_badge
                :if={Auth.OAuth.client_resources(client) == []}
                variant="neutral"
                size="sm"
              >
                {dgettext("user", "Identity only")}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={client} label={dgettext("common", "Actions")}>
            <div class="flex flex-wrap gap-2">
              <.link
                navigate={~p"/auth/oauth/clients/#{client.id}/edit"}
                class="no-underline"
              >
                <.dm_btn type="button" variant="outline" size="xs">{dgettext("common", "Edit")}</.dm_btn>
              </.link>
              <.dm_btn
                :if={client.confidential}
                type="button"
                variant="outline"
                size="xs"
                phx-click="rotate-client-secret"
                phx-value-id={client.id}
                data-confirm={dgettext("user", "Rotate secret for %{name}?", name: client.name)}
              >
                {dgettext("user", "Rotate")}
              </.dm_btn>
              <.dm_btn
                :if={!client_disabled?(client)}
                type="button"
                variant="error"
                size="xs"
                phx-click="disable-client"
                phx-value-id={client.id}
                data-confirm={dgettext("user", "Disable OAuth client %{name}?", name: client.name)}
              >
                {dgettext("common", "Disable")}
              </.dm_btn>
            </div>
            <span :if={client_disabled?(client)} class="text-sm text-on-surface-variant">
              {dgettext("common", "Disabled")}
            </span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :client_edit && @editing_client} variant="bordered">
        <:title>{dgettext("user", "Edit OAuth Client Resources")}</:title>
        <div class="mb-4">
          <div class="font-medium">{@editing_client.name}</div>
          <code class="text-xs text-on-surface-variant">{@editing_client.id}</code>
        </div>
        <form id="oauth-client-resource-form" phx-submit="update-client-resources">
          <div class="flex flex-wrap gap-4">
            <.dm_checkbox
              id="oauth-client-resource-mcp"
              name="client[resources][mcp]"
              label={dgettext("admin", "MCP (/mcp)")}
              value="true"
              checked={client_resource?(@editing_client, :mcp)}
            />
            <.dm_checkbox
              id="oauth-client-resource-v1"
              name="client[resources][v1]"
              label={dgettext("admin", "LLM API (/v1)")}
              value="true"
              checked={client_resource?(@editing_client, :v1)}
            />
          </div>
          <div class="mt-4">
            <.dm_btn type="submit" variant="primary" size="sm">{dgettext("user", "Save Resources")}</.dm_btn>
          </div>
        </form>
      </.dm_card>

      <.dm_card :if={@live_action == :client_policies} variant="bordered">
        <:title>{dgettext("navigation", "Client Policies")}</:title>
        <.dm_table id="client-policy-table" data={client_policies()} hover zebra>
          <:col :let={policy} label={dgettext("user", "Policy")}>
            <div class="font-medium">{policy.name}</div>
          </:col>
          <:col :let={policy} label={dgettext("user", "Enforcement")}>{policy.enforcement}</:col>
          <:col :let={policy} label={dgettext("common", "Status")}>
            <.dm_badge variant={policy.variant}>{policy.status}</.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :tokens} variant="bordered">
        <:title>{dgettext("user", "Issued Tokens")}</:title>
        <div :if={@tokens == []} class="py-8 text-center text-on-surface-variant">
          {dgettext("user", "No OAuth tokens issued.")}
        </div>

        <.dm_table :if={@tokens != []} id="oauth-token-table" data={@tokens} hover zebra>
          <:col :let={token} label={dgettext("user", "Token")}>
            <div class="font-medium">{token.type}</div>
            <code class="text-xs text-on-surface-variant">{token.id}</code>
          </:col>
          <:col :let={token} label={dgettext("user", "Client")}>
            <span>{client_name(token)}</span>
          </:col>
          <:col :let={token} label={dgettext("user", "Subject")}>
            <span>{subject_label(token, @users_by_id)}</span>
          </:col>
          <:col :let={token} label={dgettext("user", "Scopes")}>
            <span class="text-sm">{token.scope}</span>
          </:col>
          <:col :let={token} label={dgettext("common", "Status")}>
            <.dm_badge variant={token_status_variant(token)}>{status_label(token_status(token))}</.dm_badge>
          </:col>
          <:col :let={token} label={dgettext("user", "Expires")}>
            <span class="text-sm text-on-surface-variant">{format_unix(token.expires_at)}</span>
          </:col>
          <:col :let={token} label={dgettext("common", "Actions")}>
            <.dm_btn
              :if={token_status(token) == "Active"}
              type="button"
              variant="error"
              size="xs"
              phx-click="revoke-token"
              phx-value-id={token.id}
              data-confirm={dgettext("user", "Revoke this OAuth token?")}
            >
              {dgettext("user", "Revoke")}
            </.dm_btn>
            <span :if={token_status(token) != "Active"} class="text-sm text-on-surface-variant">
              {status_label(token_status(token))}
            </span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :tokens} variant="bordered">
        <:title>{dgettext("user", "Browser Sessions")}</:title>
        <div :if={@sessions == []} class="py-8 text-center text-on-surface-variant">
          {dgettext("user", "No browser Auth sessions.")}
        </div>

        <.dm_table :if={@sessions != []} id="auth-session-table" data={@sessions} hover zebra>
          <:col :let={session} label={dgettext("user", "Session")}>
            <div class="font-medium">auth_session</div>
            <code class="text-xs text-on-surface-variant">{session.id}</code>
          </:col>
          <:col :let={session} label={dgettext("user", "User")}>
            <div class="font-medium">{session.user.name || session.user.email}</div>
            <code class="text-xs text-on-surface-variant">{session.user.email}</code>
          </:col>
          <:col :let={session} label={dgettext("common", "Status")}>
            <.dm_badge variant={session_status_variant(session)}>{status_label(session_status(session))}</.dm_badge>
          </:col>
          <:col :let={session} label={dgettext("user", "Expires")}>
            <span class="text-sm text-on-surface-variant">{format_datetime(session.expires_at)}</span>
          </:col>
          <:col :let={session} label={dgettext("common", "Actions")}>
            <.dm_btn
              :if={session_status(session) == "Active"}
              type="button"
              variant="error"
              size="xs"
              phx-click="revoke-session"
              phx-value-id={session.id}
              data-confirm={dgettext("user", "Revoke this Auth session?")}
            >
              {dgettext("user", "Revoke")}
            </.dm_btn>
            <span :if={session_status(session) != "Active"} class="text-sm text-on-surface-variant">
              {status_label(session_status(session))}
            </span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :scopes} variant="bordered">
        <:title>{dgettext("user", "Scope Catalog")}</:title>
        <form id="oauth-scope-form" phx-submit="create-scope" class="mb-4 grid gap-3 md:grid-cols-4">
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm"
            name="scope[name]"
            placeholder="scope:name"
            required
          />
          <input
            class="rounded-md border border-outline bg-surface px-3 py-2 text-sm md:col-span-2"
            name="scope[label]"
            placeholder={dgettext("admin", "Display label")}
          />
          <label class="flex items-center gap-2 text-sm">
            <input type="hidden" name="scope[public]" value="false" />
            <input type="checkbox" name="scope[public]" value="true" checked />
            {dgettext("user", "Public")}
          </label>
          <div class="md:col-span-4">
            <.dm_btn type="submit" variant="primary" size="sm">{dgettext("user", "Create Scope")}</.dm_btn>
          </div>
        </form>

        <div :if={@scopes == []} class="py-8 text-center text-on-surface-variant">
          {dgettext("user", "No OAuth scopes configured.")}
        </div>

        <.dm_table :if={@scopes != []} id="oauth-scope-table" data={@scopes} hover zebra>
          <:col :let={scope} label={dgettext("user", "Scope")}>
            <code>{scope.name}</code>
          </:col>
          <:col :let={scope} label={dgettext("common", "Label")}>{scope.label || scope.name}</:col>
          <:col :let={scope} label={dgettext("user", "Visibility")}>
            <.dm_badge variant={if scope.public, do: "success", else: "warning"}>
              {if scope.public,
                do: dgettext("user", "Public"),
                else: dgettext("user", "Private")}
            </.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :protocol_support} variant="bordered">
        <:title>{dgettext("navigation", "Protocol Support")}</:title>
        <.dm_table id="protocol-support-table" data={protocol_capabilities()} hover zebra>
          <:col :let={capability} label={dgettext("user", "Capability")}>
            <div class="font-medium">{capability.name}</div>
          </:col>
          <:col :let={capability} label={dgettext("user", "Backplane Behavior")}>{capability.behavior}</:col>
          <:col :let={capability} label={dgettext("common", "Status")}>
            <.dm_badge variant={capability.variant}>{capability.status}</.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>
    </div>
    """
  end

  defp assign_action_data(socket, action) do
    assign(socket,
      clients: clients(action),
      overview_stats: overview_stats(),
      provider_metadata: provider_metadata(oauth_issuer()),
      scopes: scopes(action),
      sessions: sessions(action),
      tokens: tokens(action),
      users_by_id: users_by_id(action)
    )
  end

  defp clients(action) when action in [:overview, :clients, :client_edit],
    do: Auth.OAuth.list_clients()

  defp clients(_action), do: []

  defp editing_client(:client_edit, %{"id" => id}) do
    case Auth.OAuth.get_client(id) do
      nil -> {:error, :not_found}
      client -> {:ok, client}
    end
  end

  defp editing_client(_action, _params), do: {:ok, nil}

  defp scopes(action) when action in [:overview, :scopes], do: Auth.OAuth.list_scopes()
  defp scopes(_action), do: []

  defp tokens(action) when action in [:overview, :tokens], do: Auth.Tokens.list_tokens()
  defp tokens(_action), do: []

  defp sessions(:tokens), do: Auth.Accounts.list_sessions()
  defp sessions(_action), do: []

  defp users_by_id(:tokens) do
    Auth.Accounts.list_users()
    |> Map.new(&{&1.id, &1})
  end

  defp users_by_id(_action), do: %{}

  defp overview_stats do
    clients = Auth.OAuth.list_clients()
    tokens = Auth.Tokens.list_tokens()

    [
      %{
        label: dgettext("user", "Clients"),
        value: length(clients),
        note: dgettext("user", "registered OAuth apps")
      },
      %{
        label: dgettext("user", "Scopes"),
        value: length(Auth.OAuth.list_scopes()),
        note: dgettext("user", "grantable permissions")
      },
      %{
        label: dgettext("user", "Tokens"),
        value: Enum.count(tokens, &(token_status(&1) == "Active")),
        note: dgettext("user", "active access grants")
      },
      %{
        label: dgettext("user", "Users"),
        value: length(Auth.Accounts.list_users()),
        note: dgettext("user", "local auth users")
      }
    ]
  end

  defp provider_metadata(issuer) do
    [
      %{name: dgettext("user", "Issuer"),
        value: issuer,
        status: dgettext("common", "Active"),
        variant: "success"},
      %{
        name: dgettext("user", "Authorization Endpoint"),
        value: "#{issuer}/oauth/authorize",
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Token Endpoint"),
        value: "#{issuer}/oauth/token",
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "UserInfo Endpoint"),
        value: "#{issuer}/oauth/userinfo",
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Introspection Endpoint"),
        value: "#{issuer}/oauth/introspect",
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Revocation Endpoint"),
        value: "#{issuer}/oauth/revoke",
        status: dgettext("common", "Enabled"),
        variant: "success"
      }
    ]
  end

  defp client_policies do
    [
      %{
        name: dgettext("user", "Public clients require PKCE"),
        enforcement: dgettext("user", "Rejected at client registration and token exchange."),
        status: dgettext("user", "Enforced"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Redirect URIs match exactly"),
        enforcement: dgettext("user", "Authorize and token requests must use a registered URI."),
        status: dgettext("user", "Enforced"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Refresh tokens rotate"),
        enforcement: dgettext("user", "Reuse revokes the token family."),
        status: dgettext("user", "Enforced"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Implicit flow disabled"),
        enforcement: dgettext("user", "Only authorization code and refresh-token grants are exposed."),
        status: dgettext("user", "Enforced"),
        variant: "success"
      }
    ]
  end

  defp protocol_capabilities do
    [
      %{
        name: dgettext("user", "OIDC discovery"),
        behavior: dgettext("user", "/.well-known/openid-configuration advertises issuer metadata."),
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Authorization code + PKCE"),
        behavior: dgettext("user", "/oauth/authorize issues codes only after local user login."),
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "JWT access tokens"),
        behavior: dgettext("user", "Access tokens are RS256 signed and backed by server-side revocation state."),
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "UserInfo"),
        behavior: dgettext("user", "/oauth/userinfo resolves active bearer tokens to local auth users."),
        status: dgettext("common", "Enabled"),
        variant: "success"
      },
      %{
        name: dgettext("user", "Client credentials grant"),
        behavior: dgettext("user", "Not exposed in the first release."),
        status: dgettext("common", "Disabled"),
        variant: "neutral"
      }
    ]
  end

  defp page(:overview) do
    %{
      title: dgettext("navigation", "Auth Overview"),
      description: dgettext("user", "Standalone Backplane OAuth provider inventory and runtime status.")
    }
  end

  defp page(:clients) do
    %{
      title: dgettext("user", "OAuth Clients"),
      description:
        dgettext("user", "Applications allowed to request Backplane Auth authorization codes and tokens.")
    }
  end

  defp page(:client_edit) do
    %{
      title: dgettext("user", "Edit OAuth Client"),
      description: dgettext("user", "Choose which Backplane protected resources this OAuth client may access.")
    }
  end

  defp page(:providers) do
    %{
      title: dgettext("user", "OAuth Providers"),
      description:
        dgettext("user", "Provider metadata for Backplane's built-in OAuth and OIDC authorization server.")
    }
  end

  defp page(:client_policies) do
    %{
      title: dgettext("navigation", "Client Policies"),
      description: dgettext("user", "OAuth client safety rules enforced by Backplane Auth.")
    }
  end

  defp page(:protocol_support) do
    %{
      title: dgettext("navigation", "Protocol Support"),
      description: dgettext("user", "Implemented OAuth and OIDC protocol capabilities.")
    }
  end

  defp page(:tokens) do
    %{
      title: dgettext("user", "OAuth Tokens"),
      description:
        dgettext("user", "Issued authorization codes, access tokens, refresh-token families, and revocation state.")
    }
  end

  defp page(:scopes) do
    %{
      title: dgettext("user", "OAuth Scopes"),
      description: dgettext("user", "Scope catalog used by OAuth clients and RBAC role grants.")
    }
  end

  defp oauth_issuer do
    :boruta
    |> Application.get_env(Boruta.Oauth, [])
    |> Keyword.get(:issuer, "")
    |> String.trim_trailing("/")
  end

  defp scope_names(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp scope_names(_scopes), do: []

  defp client_attrs(params) do
    %{
      name: Map.get(params, "name"),
      redirect_uris: split_values(Map.get(params, "redirect_uris")),
      scopes: split_values(Map.get(params, "scopes")),
      resources: selected_resources(Map.get(params, "resources")),
      confidential: truthy?(Map.get(params, "confidential")),
      pkce: true
    }
  end

  defp selected_resources(resources) when is_map(resources) do
    [:mcp, :v1]
    |> Enum.filter(fn resource ->
      truthy?(Map.get(resources, Atom.to_string(resource)))
    end)
  end

  defp selected_resources(_resources), do: []

  defp scope_attrs(params) do
    %{
      name: Map.get(params, "name"),
      label: Map.get(params, "label"),
      public: truthy?(Map.get(params, "public"))
    }
  end

  defp split_values(value) when is_binary(value) do
    value
    |> String.split([",", "\n", "\r", "\t", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_values(_value), do: []

  defp truthy?(value) when value in [true, "true", "on", "1"], do: true
  defp truthy?(_value), do: false

  defp client_disabled?(client) do
    metadata = client.metadata || %{}
    Map.get(metadata, "disabled") || Map.get(metadata, :disabled) || false
  end

  defp client_resource?(client, resource),
    do: resource in Auth.OAuth.client_resources(client)

  defp resource_label(:mcp), do: "MCP"
  defp resource_label(:v1), do: "LLM API"

  defp resource_variant(:mcp), do: "info"
  defp resource_variant(:v1), do: "secondary"

  defp client_name(%{client: %{name: name}}) when is_binary(name) and name != "", do: name
  defp client_name(%{client_id: client_id}) when is_binary(client_id), do: client_id
  defp client_name(_token), do: dgettext("user", "Unknown client")

  defp subject_label(%{sub: sub}, users_by_id) when is_binary(sub) do
    case Map.get(users_by_id, sub) do
      %{email: email} when is_binary(email) -> email
      _user -> sub
    end
  end

  defp subject_label(_token, _users_by_id), do: dgettext("user", "Unknown subject")

  defp token_status(%{revoked_at: %DateTime{}}), do: "Revoked"

  defp token_status(%{expires_at: expires_at}) when is_integer(expires_at) do
    if expires_at > System.system_time(:second), do: "Active", else: "Expired"
  end

  defp token_status(_token), do: "Unknown"

  defp session_status(%{revoked_at: %DateTime{}}), do: "Revoked"

  defp session_status(%{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: "Active", else: "Expired"
  end

  defp session_status(_session), do: "Unknown"

  defp status_label("Active"), do: dgettext("common", "Active")
  defp status_label("Revoked"), do: dgettext("user", "Revoked")
  defp status_label("Expired"), do: dgettext("user", "Expired")
  defp status_label(_status), do: dgettext("common", "Unknown")

  defp token_status_variant(token) do
    case token_status(token) do
      "Active" -> "success"
      "Revoked" -> "error"
      "Expired" -> "warning"
      _status -> "neutral"
    end
  end

  defp session_status_variant(session) do
    case session_status(session) do
      "Active" -> "success"
      "Revoked" -> "error"
      "Expired" -> "warning"
      _status -> "neutral"
    end
  end

  defp format_unix(expires_at) when is_integer(expires_at) do
    expires_at
    |> DateTime.from_unix!()
    |> format_datetime()
  end

  defp format_unix(_expires_at), do: dgettext("common", "Unknown")

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
