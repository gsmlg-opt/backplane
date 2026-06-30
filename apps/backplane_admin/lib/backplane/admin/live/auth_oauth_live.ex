defmodule Backplane.Admin.AuthOAuthLive do
  use Backplane.Admin, :live_view

  alias Backplane.Auth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       clients: [],
       current_path: "/auth/overview",
       issuer: nil,
       overview_stats: [],
       page: page(:overview),
       provider_metadata: [],
       scopes: [],
       tokens: [],
       users_by_id: %{}
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    action = socket.assigns.live_action

    {:noreply,
     socket
     |> assign(current_path: URI.parse(uri).path, issuer: oauth_issuer(), page: page(action))
     |> assign_action_data(action)}
  end

  @impl true
  def handle_event("disable-client", %{"id" => id}, socket) do
    with %{name: name} = client <- Auth.OAuth.get_client(id),
         {:ok, _client} <- Auth.OAuth.disable_client(client) do
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
       |> put_flash(:info, "OAuth client disabled.")
       |> assign_action_data(socket.assigns.live_action)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "OAuth client was not found.")}
    end
  end

  def handle_event("revoke-token", %{"id" => id}, socket) do
    case Auth.Tokens.revoke_token_by_id(id) do
      {:ok, _token} ->
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
         |> put_flash(:info, "OAuth token revoked.")
         |> assign_action_data(socket.assigns.live_action)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "OAuth token was not found.")}
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

      <.dm_card variant="bordered">
        <:title>Authorization Server</:title>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">Issuer</div>
            <code class="mt-1 block break-all text-sm">{@issuer}</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">Authorize</div>
            <code class="mt-1 block break-all text-sm">/oauth/authorize</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">Token</div>
            <code class="mt-1 block break-all text-sm">/oauth/token</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">JWKS</div>
            <code class="mt-1 block break-all text-sm">/oauth/jwks</code>
          </div>
        </div>
      </.dm_card>

      <.dm_card :if={@live_action == :overview} variant="bordered">
        <:title>Auth Inventory</:title>
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
        <:title>Backplane OAuth Provider</:title>
        <.dm_table id="auth-provider-metadata-table" data={@provider_metadata} hover zebra>
          <:col :let={item} label="Capability">
            <div class="font-medium">{item.name}</div>
          </:col>
          <:col :let={item} label="Value">
            <code class="break-all text-xs text-on-surface-variant">{item.value}</code>
          </:col>
          <:col :let={item} label="Status">
            <.dm_badge variant={item.variant}>{item.status}</.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :clients} variant="bordered">
        <:title>Registered Clients</:title>
        <div :if={@clients == []} class="py-8 text-center text-on-surface-variant">
          No OAuth clients registered.
        </div>

        <.dm_table :if={@clients != []} id="oauth-client-table" data={@clients} hover zebra>
          <:col :let={client} label="Client">
            <div class="font-medium">{client.name}</div>
            <code class="text-xs text-on-surface-variant">{client.id}</code>
          </:col>
          <:col :let={client} label="Type">
            <div class="flex flex-wrap gap-1">
              <.dm_badge variant={if client.confidential, do: "info", else: "secondary"}>
                {if client.confidential, do: "Confidential", else: "Public"}
              </.dm_badge>
              <.dm_badge :if={client.pkce} variant="success">PKCE</.dm_badge>
            </div>
          </:col>
          <:col :let={client} label="Status">
            <.dm_badge variant={if client_disabled?(client), do: "error", else: "success"}>
              {if client_disabled?(client), do: "Disabled", else: "Enabled"}
            </.dm_badge>
          </:col>
          <:col :let={client} label="Redirect URIs">
            <div class="space-y-1">
              <code
                :for={uri <- client.redirect_uris}
                class="block break-all text-xs text-on-surface-variant"
              >
                {uri}
              </code>
            </div>
          </:col>
          <:col :let={client} label="Scopes">
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={scope <- scope_names(client.authorized_scopes)} variant="neutral" size="sm">
                {scope}
              </.dm_badge>
            </div>
          </:col>
          <:col :let={client} label="Actions">
            <.dm_btn
              :if={!client_disabled?(client)}
              type="button"
              variant="error"
              size="xs"
              phx-click="disable-client"
              phx-value-id={client.id}
              data-confirm={"Disable OAuth client #{client.name}?"}
            >
              Disable
            </.dm_btn>
            <span :if={client_disabled?(client)} class="text-sm text-on-surface-variant">
              Disabled
            </span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :client_policies} variant="bordered">
        <:title>Client Policies</:title>
        <.dm_table id="client-policy-table" data={client_policies()} hover zebra>
          <:col :let={policy} label="Policy">
            <div class="font-medium">{policy.name}</div>
          </:col>
          <:col :let={policy} label="Enforcement">{policy.enforcement}</:col>
          <:col :let={policy} label="Status">
            <.dm_badge variant={policy.variant}>{policy.status}</.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :tokens} variant="bordered">
        <:title>Issued Tokens</:title>
        <div :if={@tokens == []} class="py-8 text-center text-on-surface-variant">
          No OAuth tokens issued.
        </div>

        <.dm_table :if={@tokens != []} id="oauth-token-table" data={@tokens} hover zebra>
          <:col :let={token} label="Token">
            <div class="font-medium">{token.type}</div>
            <code class="text-xs text-on-surface-variant">{token.id}</code>
          </:col>
          <:col :let={token} label="Client">
            <span>{client_name(token)}</span>
          </:col>
          <:col :let={token} label="Subject">
            <span>{subject_label(token, @users_by_id)}</span>
          </:col>
          <:col :let={token} label="Scopes">
            <span class="text-sm">{token.scope}</span>
          </:col>
          <:col :let={token} label="Status">
            <.dm_badge variant={token_status_variant(token)}>{token_status(token)}</.dm_badge>
          </:col>
          <:col :let={token} label="Expires">
            <span class="text-sm text-on-surface-variant">{format_unix(token.expires_at)}</span>
          </:col>
          <:col :let={token} label="Actions">
            <.dm_btn
              :if={token_status(token) == "Active"}
              type="button"
              variant="error"
              size="xs"
              phx-click="revoke-token"
              phx-value-id={token.id}
              data-confirm="Revoke this OAuth token?"
            >
              Revoke
            </.dm_btn>
            <span :if={token_status(token) != "Active"} class="text-sm text-on-surface-variant">
              {token_status(token)}
            </span>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :scopes} variant="bordered">
        <:title>Scope Catalog</:title>
        <div :if={@scopes == []} class="py-8 text-center text-on-surface-variant">
          No OAuth scopes configured.
        </div>

        <.dm_table :if={@scopes != []} id="oauth-scope-table" data={@scopes} hover zebra>
          <:col :let={scope} label="Scope">
            <code>{scope.name}</code>
          </:col>
          <:col :let={scope} label="Label">{scope.label || scope.name}</:col>
          <:col :let={scope} label="Visibility">
            <.dm_badge variant={if scope.public, do: "success", else: "warning"}>
              {if scope.public, do: "Public", else: "Private"}
            </.dm_badge>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action == :protocol_support} variant="bordered">
        <:title>Protocol Support</:title>
        <.dm_table id="protocol-support-table" data={protocol_capabilities()} hover zebra>
          <:col :let={capability} label="Capability">
            <div class="font-medium">{capability.name}</div>
          </:col>
          <:col :let={capability} label="Backplane Behavior">{capability.behavior}</:col>
          <:col :let={capability} label="Status">
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
      tokens: tokens(action),
      users_by_id: users_by_id(action)
    )
  end

  defp clients(action) when action in [:overview, :clients], do: Auth.OAuth.list_clients()
  defp clients(_action), do: []

  defp scopes(action) when action in [:overview, :scopes], do: Auth.OAuth.list_scopes()
  defp scopes(_action), do: []

  defp tokens(action) when action in [:overview, :tokens], do: Auth.Tokens.list_tokens()
  defp tokens(_action), do: []

  defp users_by_id(:tokens) do
    Auth.Accounts.list_users()
    |> Map.new(&{&1.id, &1})
  end

  defp users_by_id(_action), do: %{}

  defp overview_stats do
    clients = Auth.OAuth.list_clients()
    tokens = Auth.Tokens.list_tokens()

    [
      %{label: "Clients", value: length(clients), note: "registered OAuth apps"},
      %{label: "Scopes", value: length(Auth.OAuth.list_scopes()), note: "grantable permissions"},
      %{
        label: "Tokens",
        value: Enum.count(tokens, &(token_status(&1) == "Active")),
        note: "active access grants"
      },
      %{label: "Users", value: length(Auth.Accounts.list_users()), note: "local auth users"}
    ]
  end

  defp provider_metadata(issuer) do
    [
      %{name: "Issuer", value: issuer, status: "Active", variant: "success"},
      %{
        name: "Authorization Endpoint",
        value: "#{issuer}/oauth/authorize",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "Token Endpoint",
        value: "#{issuer}/oauth/token",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "UserInfo Endpoint",
        value: "#{issuer}/oauth/userinfo",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "Introspection Endpoint",
        value: "#{issuer}/oauth/introspect",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "Revocation Endpoint",
        value: "#{issuer}/oauth/revoke",
        status: "Enabled",
        variant: "success"
      }
    ]
  end

  defp client_policies do
    [
      %{
        name: "Public clients require PKCE",
        enforcement: "Rejected at client registration and token exchange.",
        status: "Enforced",
        variant: "success"
      },
      %{
        name: "Redirect URIs match exactly",
        enforcement: "Authorize and token requests must use a registered URI.",
        status: "Enforced",
        variant: "success"
      },
      %{
        name: "Refresh tokens rotate",
        enforcement: "Reuse revokes the token family.",
        status: "Enforced",
        variant: "success"
      },
      %{
        name: "Implicit flow disabled",
        enforcement: "Only authorization code and refresh-token grants are exposed.",
        status: "Enforced",
        variant: "success"
      }
    ]
  end

  defp protocol_capabilities do
    [
      %{
        name: "OIDC discovery",
        behavior: "/.well-known/openid-configuration advertises issuer metadata.",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "Authorization code + PKCE",
        behavior: "/oauth/authorize issues codes only after local user login.",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "JWT access tokens",
        behavior: "Access tokens are RS256 signed and backed by server-side revocation state.",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "UserInfo",
        behavior: "/oauth/userinfo resolves active bearer tokens to local auth users.",
        status: "Enabled",
        variant: "success"
      },
      %{
        name: "Client credentials grant",
        behavior: "Not exposed in the first release.",
        status: "Disabled",
        variant: "neutral"
      }
    ]
  end

  defp page(:overview) do
    %{
      title: "Auth Overview",
      description: "Standalone Backplane OAuth provider inventory and runtime status."
    }
  end

  defp page(:clients) do
    %{
      title: "OAuth Clients",
      description:
        "Applications allowed to request Backplane Auth authorization codes and tokens."
    }
  end

  defp page(:providers) do
    %{
      title: "OAuth Providers",
      description:
        "Provider metadata for Backplane's built-in OAuth and OIDC authorization server."
    }
  end

  defp page(:client_policies) do
    %{
      title: "Client Policies",
      description: "OAuth client safety rules enforced by Backplane Auth."
    }
  end

  defp page(:protocol_support) do
    %{
      title: "Protocol Support",
      description: "Implemented OAuth and OIDC protocol capabilities."
    }
  end

  defp page(:tokens) do
    %{
      title: "OAuth Tokens",
      description:
        "Issued authorization codes, access tokens, refresh-token families, and revocation state."
    }
  end

  defp page(:scopes) do
    %{
      title: "OAuth Scopes",
      description: "Scope catalog used by OAuth clients and RBAC role grants."
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

  defp client_disabled?(client) do
    metadata = client.metadata || %{}
    Map.get(metadata, "disabled") || Map.get(metadata, :disabled) || false
  end

  defp client_name(%{client: %{name: name}}) when is_binary(name) and name != "", do: name
  defp client_name(%{client_id: client_id}) when is_binary(client_id), do: client_id
  defp client_name(_token), do: "Unknown client"

  defp subject_label(%{sub: sub}, users_by_id) when is_binary(sub) do
    case Map.get(users_by_id, sub) do
      %{email: email} when is_binary(email) -> email
      _user -> sub
    end
  end

  defp subject_label(_token, _users_by_id), do: "Unknown subject"

  defp token_status(%{revoked_at: %DateTime{}}), do: "Revoked"

  defp token_status(%{expires_at: expires_at}) when is_integer(expires_at) do
    if expires_at > System.system_time(:second), do: "Active", else: "Expired"
  end

  defp token_status(_token), do: "Unknown"

  defp token_status_variant(token) do
    case token_status(token) do
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

  defp format_unix(_expires_at), do: "Unknown"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
end
