defmodule Backplane.Admin.AuthOAuthLive do
  use Backplane.Admin, :live_view

  alias Backplane.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       current_path: "/auth/overview",
       providers: [],
       issuer: nil,
       page: page(:overview)
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    action = socket.assigns.live_action

    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       providers: providers(action),
       issuer: oauth_issuer(),
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

      <.dm_card variant="bordered">
        <:title>Authorization Server</:title>
        <div class="grid gap-4 sm:grid-cols-2">
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">Issuer</div>
            <code class="mt-1 block break-all text-sm">{@issuer}</code>
          </div>
          <div>
            <div class="text-xs font-medium uppercase text-on-surface-variant">MCP Resource</div>
            <code class="mt-1 block break-all text-sm">/mcp</code>
          </div>
        </div>
      </.dm_card>

      <.dm_card :if={@live_action == :providers} variant="bordered">
        <:title>Identity Providers</:title>
        <div :if={@providers == []} class="py-8 text-center text-on-surface-variant">
          No inbound identity providers configured.
        </div>

        <.dm_table :if={@providers != []} id="auth-provider-table" data={@providers} hover zebra>
          <:col :let={provider} label="Name">
            <div class="font-medium">{provider.name}</div>
            <code class="text-xs text-on-surface-variant">{provider.slug}</code>
          </:col>
          <:col :let={provider} label="Kind">
            <.dm_badge variant="info">{format_kind(provider.kind)}</.dm_badge>
          </:col>
          <:col :let={provider} label="Status">
            <.dm_badge variant={if provider.enabled, do: "success", else: "error"}>
              {if provider.enabled, do: "Enabled", else: "Disabled"}
            </.dm_badge>
          </:col>
          <:col :let={provider} label="Issuer / Authorization URL">
            <code class="break-all text-xs text-on-surface-variant">
              {provider.issuer || provider.authorization_url}
            </code>
          </:col>
          <:col :let={provider} label="Domains">
            <div class="flex flex-wrap gap-1">
              <.dm_badge
                :for={domain <- provider.allowed_email_domains}
                variant="neutral"
                size="sm"
              >
                {domain}
              </.dm_badge>
              <span :if={provider.allowed_email_domains == []} class="text-sm text-on-surface-variant">
                Any verified email
              </span>
            </div>
          </:col>
          <:col :let={provider} label="Scopes">
            <div class="flex flex-wrap gap-1">
              <.dm_badge :for={scope <- provider.scopes} variant="neutral" size="sm">
                {scope}
              </.dm_badge>
            </div>
          </:col>
        </.dm_table>
      </.dm_card>

      <.dm_card :if={@live_action != :providers} variant="bordered">
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

  defp providers(:providers), do: Accounts.list_auth_providers()
  defp providers(_action), do: []

  defp page(:overview) do
    %{
      title: "Auth Overview",
      description: "Operational status for Backplane inbound OAuth, MCP authorization, and RBAC.",
      card_title: "Readiness Checklist",
      items: [
        %{
          title: "Authorization Server",
          body:
            "Backplane issues its own MCP access tokens instead of accepting upstream IdP tokens."
        },
        %{
          title: "Identity Providers",
          body:
            "Inbound OIDC/OAuth2 providers authenticate humans before MCP client authorization."
        },
        %{
          title: "RBAC Scope Injection",
          body: "Runtime roles will determine the OAuth scopes granted to each user token."
        },
        %{
          title: "Audit Trail",
          body: "Auth audit events will track login, token, client, provider, and role changes."
        }
      ]
    }
  end

  defp page(:clients) do
    %{
      title: "OAuth Clients",
      description: "Registered MCP OAuth clients created through dynamic client registration.",
      card_title: "Client Management",
      items: [
        %{
          title: "Registered Clients",
          body:
            "List DCR-created clients with redirect URIs, client type, status, scopes, and last-used time."
        },
        %{
          title: "Operational Actions",
          body:
            "Disable clients and revoke their active tokens without deleting historical audit context."
        }
      ]
    }
  end

  defp page(:providers) do
    %{
      title: "OAuth Providers",
      description:
        "Inbound identity providers used when a human signs in before authorizing an MCP client.",
      card_title: "Identity Providers",
      items: []
    }
  end

  defp page(:client_policies) do
    %{
      title: "Client Policies",
      description: "OAuth client safety rules inspired by Keycloak client policies.",
      card_title: "Policy Controls",
      items: [
        %{
          title: "PKCE Required",
          body: "Public MCP clients must use authorization code flow with PKCE."
        },
        %{
          title: "Redirect URI Rules",
          body:
            "Dynamic registrations accept loopback redirect URIs for local clients and HTTPS for hosted clients."
        },
        %{
          title: "Refresh Token Rotation",
          body: "Refresh tokens should rotate, and reuse should invalidate the token family."
        },
        %{
          title: "Client Lifecycle",
          body:
            "Operators need disable, revoke-all-tokens, and stale-registration cleanup controls."
        }
      ]
    }
  end

  defp page(:protocol_support) do
    %{
      title: "Protocol Support",
      description: "Read-only OAuth and MCP protocol capability status.",
      card_title: "Compliance Profile",
      items: [
        %{
          title: "OAuth 2.0 Compatibility",
          body: "Authorization code with PKCE remains the supported compatibility path."
        },
        %{
          title: "OAuth 2.1 Readiness",
          body:
            "Implicit and password grants stay unsupported; PKCE and bearer-token hygiene are required."
        },
        %{
          title: "MCP Protected Resource Metadata",
          body:
            "The MCP resource metadata document advertises the authorization server and supported scopes."
        },
        %{
          title: "Resource Indicators",
          body: "Tokens are audience-bound to the configured Backplane MCP resource."
        }
      ]
    }
  end

  defp page(:tokens) do
    %{
      title: "OAuth Tokens",
      description: "Issued MCP access and refresh token management.",
      card_title: "Token Management",
      items: [
        %{
          title: "Opaque Access Tokens",
          body:
            "Backplane-issued MCP access tokens are stored server-side and validated by introspection."
        },
        %{
          title: "Revocation",
          body: "Token revocation belongs here as the OAuth rollout adds operational controls."
        }
      ]
    }
  end

  defp page(:scopes) do
    %{
      title: "OAuth Scopes",
      description: "OAuth scope catalog and MCP tool access mapping.",
      card_title: "Scope Management",
      items: [
        %{
          title: "MCP Tool Scopes",
          body: "Scopes map OAuth grants to the tool access rules enforced by MCP auth."
        },
        %{
          title: "RBAC Integration",
          body: "Role assignments determine which OAuth scopes a human user can authorize."
        }
      ]
    }
  end

  defp oauth_issuer do
    :boruta
    |> Application.get_env(Boruta.Oauth, [])
    |> Keyword.get(:issuer, "")
  end

  defp format_kind(kind) when is_binary(kind), do: String.upcase(kind)
  defp format_kind(kind), do: to_string(kind)
end
