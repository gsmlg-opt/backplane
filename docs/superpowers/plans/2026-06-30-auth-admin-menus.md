# Auth Admin Menus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Keycloak-informed Auth admin menu structure for Backplane without implementing the deeper OAuth/RBAC domain model yet.

**Architecture:** Keep Auth as a top-level admin section owned by `backplane_admin`. Use route-driven LiveViews with data loaded in `handle_params/3`, preserving the current split between admin UI, API OAuth endpoints, and system domain contexts. The first pass creates the navigable shell and read-only/status surfaces for Overview, OAuth, RBAC, and Audit while using real data only where schemas already exist.

**Tech Stack:** Elixir, Phoenix LiveView, Phoenix DuskMoon components, Backplane.Accounts, Boruta Ecto tables, ExUnit LiveView tests.

---

## Scope

This plan builds the admin menu and page shell only. It does not implement OAuth authorization endpoints, token issuance, RBAC persistence, Boruta admin context wrappers, or admin permission enforcement. Those belong in later OAuth/RBAC phases.

The current uncommitted UI already has a top-level Auth menu and basic OAuth/RBAC pages. This plan reshapes that work into the researched menu model:

```text
Auth
  Overview
  OAuth
    Providers
    Clients
    Client Policies
    Tokens
    Scopes
    Protocol Support
  RBAC
    Users
    Roles
    Assignments
  Audit
```

## File Structure

- Modify `apps/backplane_admin/lib/backplane/admin/components/layouts.ex`
  - Owns top-level nav and Auth left-nav grouping.
  - Should expose Auth as a top-level item beside System.
  - Should not expose OAuth 2.0 and OAuth 2.1 as primary menu items.

- Modify `apps/backplane_admin/lib/backplane/admin/router.ex`
  - Owns admin route registration.
  - Adds stable routes for every Auth menu item.

- Modify `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex`
  - Owns OAuth Overview, Providers, Clients, Client Policies, Tokens, Scopes, and Protocol Support pages.
  - Uses `handle_params/3` for all data loading.
  - Lists real inbound identity providers through `Backplane.Accounts.list_auth_providers/0`.
  - Shows placeholder/readiness content for OAuth clients, policies, tokens, scopes, and protocol support until domain wrappers land.

- Modify `apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex`
  - Owns RBAC Users, Roles, and Assignments pages.
  - Uses real users and bootstrap admin status where available.
  - Shows placeholder/readiness content for runtime roles and assignments until `roles`, `role_scopes`, and `user_roles` land.

- Create `apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex`
  - Owns Auth Audit page.
  - Shows event categories and explicitly states that persistent audit event storage is not landed yet.

- Modify `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`
  - Covers navigation, route rendering, provider listing, RBAC users, and audit route rendering.

---

### Task 1: Update Auth Menu Contract Tests

**Files:**
- Modify: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Replace the top-level navigation test**

Replace the existing `"renders Auth as a top-level section with OAuth and RBAC groups"` test with:

```elixir
test "renders Auth as a top-level section with OAuth, RBAC, and Audit groups", %{conn: conn} do
  {:ok, _view, html} = live(conn, "/auth/overview")

  assert html =~ ~s(href="/auth/overview")
  assert html =~ ">Auth<"
  assert html =~ "Overview"
  assert html =~ "OAuth"
  assert html =~ "Providers"
  assert html =~ "Clients"
  assert html =~ "Client Policies"
  assert html =~ "Tokens"
  assert html =~ "Scopes"
  assert html =~ "Protocol Support"
  assert html =~ "RBAC"
  assert html =~ "Users"
  assert html =~ "Roles"
  assert html =~ "Assignments"
  assert html =~ "Audit"

  refute html =~ "OAuth 2.0"
  refute html =~ "OAuth 2.1"
end
```

- [ ] **Step 2: Replace the OAuth route test**

Replace the existing `"OAuth menu routes render management surfaces"` test with:

```elixir
test "OAuth menu routes render management surfaces", %{conn: conn} do
  for {path, heading} <- [
        {"/auth/overview", "Auth Overview"},
        {"/auth/oauth/providers", "OAuth Providers"},
        {"/auth/oauth/clients", "OAuth Clients"},
        {"/auth/oauth/client-policies", "Client Policies"},
        {"/auth/oauth/tokens", "OAuth Tokens"},
        {"/auth/oauth/scopes", "OAuth Scopes"},
        {"/auth/oauth/protocol-support", "Protocol Support"}
      ] do
    {:ok, _view, html} = live(conn, path)
    assert html =~ heading
  end
end
```

- [ ] **Step 3: Add RBAC and Audit route tests**

Add these tests after the OAuth route test:

```elixir
test "RBAC menu routes render management surfaces", %{conn: conn} do
  for {path, heading} <- [
        {"/auth/rbac/users", "RBAC Users"},
        {"/auth/rbac/roles", "RBAC Roles"},
        {"/auth/rbac/assignments", "Role Assignments"}
      ] do
    {:ok, _view, html} = live(conn, path)
    assert html =~ heading
  end
end

test "Auth audit route renders audit surface", %{conn: conn} do
  {:ok, _view, html} = live(conn, "/auth/audit")

  assert html =~ "Auth Audit"
  assert html =~ "Login events"
  assert html =~ "Token events"
  assert html =~ "Role events"
end
```

- [ ] **Step 4: Update the provider listing test path**

Keep the existing provider fixture and assertions, but ensure the live route is:

```elixir
{:ok, _view, html} = live(conn, "/auth/oauth/providers")
```

- [ ] **Step 5: Update the RBAC user test path and heading**

In `"RBAC settings lists human users and bootstrap admin status"`, replace:

```elixir
{:ok, _view, html} = live(conn, "/auth/rbac")

assert html =~ "RBAC Settings"
```

with:

```elixir
{:ok, _view, html} = live(conn, "/auth/rbac/users")

assert html =~ "RBAC Users"
```

- [ ] **Step 6: Run the focused test and verify it fails**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: FAIL because `/auth/overview`, `/auth/oauth/client-policies`, `/auth/oauth/protocol-support`, `/auth/rbac/users`, `/auth/rbac/roles`, `/auth/rbac/assignments`, and `/auth/audit` are not wired yet.

---

### Task 2: Update Layout Navigation

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/components/layouts.ex`
- Test: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Point the top-level Auth item at Overview**

In `top_nav_items/0`, change the Auth entry to:

```elixir
%{label: "Auth", path: "/auth/overview", section: :auth}
```

- [ ] **Step 2: Replace the Auth left-nav block**

Replace the existing `:auth ->` block in `left_nav_items/1` with:

```elixir
:auth ->
  [
    %{label: "Overview", path: "/auth/overview", icon: "view-dashboard-outline"},
    %{
      label: "OAuth",
      icon: "shield-key",
      items: [
        %{label: "Providers", path: "/auth/oauth/providers", icon: "account-switch"},
        %{label: "Clients", path: "/auth/oauth/clients", icon: "application-braces"},
        %{label: "Client Policies", path: "/auth/oauth/client-policies", icon: "shield-check"},
        %{label: "Tokens", path: "/auth/oauth/tokens", icon: "key-chain"},
        %{label: "Scopes", path: "/auth/oauth/scopes", icon: "format-list-checks"},
        %{label: "Protocol Support", path: "/auth/oauth/protocol-support", icon: "protocol"}
      ]
    },
    %{
      label: "RBAC",
      icon: "account-key",
      items: [
        %{label: "Users", path: "/auth/rbac/users", icon: "account-group"},
        %{label: "Roles", path: "/auth/rbac/roles", icon: "account-cog"},
        %{label: "Assignments", path: "/auth/rbac/assignments", icon: "account-multiple-check"}
      ]
    },
    %{label: "Audit", path: "/auth/audit", icon: "text-box-search"}
  ]
```

- [ ] **Step 3: Run the focused test**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: still FAIL because routes and LiveView actions are not complete.

---

### Task 3: Wire Auth Routes

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex`
- Test: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Replace current Auth routes**

Replace the current Auth route block:

```elixir
live("/auth/oauth", AuthOAuthLive, :providers)
live("/auth/oauth/clients", AuthOAuthLive, :clients)
live("/auth/oauth/providers", AuthOAuthLive, :providers)
live("/auth/oauth/oauth-2-0", AuthOAuthLive, :oauth_2_0)
live("/auth/oauth/oauth-2-1", AuthOAuthLive, :oauth_2_1)
live("/auth/oauth/tokens", AuthOAuthLive, :tokens)
live("/auth/oauth/scopes", AuthOAuthLive, :scopes)
live("/auth/rbac", AuthRbacLive, :index)
```

with:

```elixir
live("/auth/overview", AuthOAuthLive, :overview)
live("/auth/oauth", AuthOAuthLive, :providers)
live("/auth/oauth/providers", AuthOAuthLive, :providers)
live("/auth/oauth/clients", AuthOAuthLive, :clients)
live("/auth/oauth/client-policies", AuthOAuthLive, :client_policies)
live("/auth/oauth/tokens", AuthOAuthLive, :tokens)
live("/auth/oauth/scopes", AuthOAuthLive, :scopes)
live("/auth/oauth/protocol-support", AuthOAuthLive, :protocol_support)
live("/auth/rbac", AuthRbacLive, :users)
live("/auth/rbac/users", AuthRbacLive, :users)
live("/auth/rbac/roles", AuthRbacLive, :roles)
live("/auth/rbac/assignments", AuthRbacLive, :assignments)
live("/auth/audit", AuthAuditLive, :index)
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: FAIL because `AuthOAuthLive` does not define the new page actions, `AuthRbacLive` does not render action-specific pages, and `AuthAuditLive` does not exist.

---

### Task 4: Reshape OAuth LiveView Pages

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex`
- Test: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Update default assigns in `mount/3`**

Use this shape:

```elixir
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
```

- [ ] **Step 2: Keep data loading in `handle_params/3`**

Ensure `handle_params/3` remains the only place that reads providers or OAuth issuer:

```elixir
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
```

- [ ] **Step 3: Replace old OAuth 2.0 / OAuth 2.1 page functions**

Delete `page(:oauth_2_0)` and `page(:oauth_2_1)`.

Add these page functions:

```elixir
defp page(:overview) do
  %{
    title: "Auth Overview",
    description: "Operational status for Backplane inbound OAuth, MCP authorization, and RBAC.",
    card_title: "Readiness Checklist",
    items: [
      %{
        title: "Authorization Server",
        body: "Backplane issues its own MCP access tokens instead of accepting upstream IdP tokens."
      },
      %{
        title: "Identity Providers",
        body: "Inbound OIDC/OAuth2 providers authenticate humans before MCP client authorization."
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
        body: "Dynamic registrations accept loopback redirect URIs for local clients and HTTPS for hosted clients."
      },
      %{
        title: "Refresh Token Rotation",
        body: "Refresh tokens should rotate, and reuse should invalidate the token family."
      },
      %{
        title: "Client Lifecycle",
        body: "Operators need disable, revoke-all-tokens, and stale-registration cleanup controls."
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
        body: "Implicit and password grants stay unsupported; PKCE and bearer-token hygiene are required."
      },
      %{
        title: "MCP Protected Resource Metadata",
        body: "The MCP resource metadata document advertises the authorization server and supported scopes."
      },
      %{
        title: "Resource Indicators",
        body: "Tokens are audience-bound to the configured Backplane MCP resource."
      }
    ]
  }
end
```

- [ ] **Step 4: Keep existing entity page functions**

Keep `page(:providers)`, `page(:clients)`, `page(:tokens)`, and `page(:scopes)`, but update `page(:clients)` so it no longer owns DCR policy alone:

```elixir
defp page(:clients) do
  %{
    title: "OAuth Clients",
    description: "Registered MCP OAuth clients created through dynamic client registration.",
    card_title: "Client Management",
    items: [
      %{
        title: "Registered Clients",
        body: "List DCR-created clients with redirect URIs, client type, status, scopes, and last-used time."
      },
      %{
        title: "Operational Actions",
        body: "Disable clients and revoke their active tokens without deleting historical audit context."
      }
    ]
  }
end
```

- [ ] **Step 5: Run the focused test**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: RBAC and Audit assertions still FAIL until later tasks.

---

### Task 5: Reshape RBAC LiveView Pages

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex`
- Test: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Add page assign defaults in `mount/3`**

Change `mount/3` to:

```elixir
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
```

- [ ] **Step 2: Load page state in `handle_params/3`**

Change `handle_params/3` to:

```elixir
@impl true
def handle_params(_params, uri, socket) do
  action = socket.assigns.live_action

  {:noreply,
   assign(socket,
     current_path: URI.parse(uri).path,
     bootstrap_admin_emails: Accounts.bootstrap_admin_emails(),
     users: users(action),
     page: page(action)
   )}
end
```

Add:

```elixir
defp users(:users), do: Accounts.list_users()
defp users(_action), do: []
```

- [ ] **Step 3: Update the top page heading in `render/1`**

Replace the static heading block with:

```elixir
<div>
  <h1 class="text-2xl font-bold">{@page.title}</h1>
  <p class="mt-1 text-sm text-on-surface-variant">{@page.description}</p>
</div>
```

- [ ] **Step 4: Render users only on `:users`**

Wrap the existing Users card with:

```elixir
<.dm_card :if={@live_action == :users} variant="bordered">
```

- [ ] **Step 5: Add placeholder cards for Roles and Assignments**

Add this card after the Users card:

```elixir
<.dm_card :if={@live_action != :users} variant="bordered">
  <:title>{@page.card_title}</:title>
  <div class="grid gap-4 lg:grid-cols-2">
    <div :for={item <- @page.items} class="rounded-md border border-outline-variant p-4">
      <div class="text-sm font-medium">{item.title}</div>
      <p class="mt-1 text-sm text-on-surface-variant">{item.body}</p>
    </div>
  </div>
</.dm_card>
```

- [ ] **Step 6: Add RBAC page functions**

Add:

```elixir
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
        body: "The UI should preview the final scope set that will be injected into future OAuth tokens."
      }
    ]
  }
end
```

- [ ] **Step 7: Run the focused test**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: Audit route still FAILS until `AuthAuditLive` is added.

---

### Task 6: Add Auth Audit LiveView

**Files:**
- Create: `apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex`
- Test: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Create the LiveView module**

Create `apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex`:

```elixir
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
        body: "Track upstream provider login attempts, successes, failures, and linked identities."
      },
      %{
        title: "Token events",
        body: "Track authorization code issuance, token exchange, refresh, revocation, and reuse detection."
      },
      %{
        title: "Client events",
        body: "Track dynamic client registrations, client disablement, and token revocation by client."
      },
      %{
        title: "Role events",
        body: "Track role creation, scope changes, user assignment, and assignment removal."
      }
    ]
  end
end
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: PASS.

---

### Task 7: Verify Admin Test Scope

**Files:**
- Test: `apps/backplane_admin/test`

- [ ] **Step 1: Run the admin app test suite**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test
```

Expected: PASS.

- [ ] **Step 2: Run the focused Auth test again**

Run:

```bash
devenv shell -- mix test apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: PASS.

- [ ] **Step 3: Check formatting for touched files**

Run:

```bash
devenv shell -- mix format --check-formatted \
  apps/backplane_admin/lib/backplane/admin/components/layouts.ex \
  apps/backplane_admin/lib/backplane/admin/router.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex \
  apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: PASS with no file rewrites required.

- [ ] **Step 4: Check whitespace**

Run:

```bash
git diff --check
```

Expected: no output.

---

### Task 8: Commit Menu Shell Changes

**Files:**
- Modify: `apps/backplane_admin/lib/backplane/admin/components/layouts.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/router.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex`
- Modify: `apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex`
- Create: `apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex`
- Modify: `apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs`

- [ ] **Step 1: Review changed files**

Run:

```bash
git status --short
git diff -- apps/backplane_admin/lib/backplane/admin/components/layouts.ex \
  apps/backplane_admin/lib/backplane/admin/router.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex \
  apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

Expected: diff only includes Auth admin menu/page/test changes.

- [ ] **Step 2: Stage only menu shell files**

Run:

```bash
git add \
  apps/backplane_admin/lib/backplane/admin/components/layouts.ex \
  apps/backplane_admin/lib/backplane/admin/router.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_oauth_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_rbac_live.ex \
  apps/backplane_admin/lib/backplane/admin/live/auth_audit_live.ex \
  apps/backplane_admin/test/backplane/admin/live/auth_settings_live_test.exs
```

- [ ] **Step 3: Commit**

Run:

```bash
git commit -m "feat(admin): add auth menu shell"
```

Expected: commit succeeds. Do not include unrelated files such as MCP transport tests unless the implementation pass also intentionally needs them.

---

## Self-Review

- Spec coverage: Covers the researched Auth menu model, Keycloak-inspired client policies, entity-first OAuth/RBAC pages, and audit shell.
- Scope check: Excludes OAuth endpoint implementation, token issuance, RBAC database tables, and domain contexts. Those are intentionally future plans.
- Placeholder scan: Placeholder UI is explicit product behavior for not-yet-landed domain surfaces; no task contains unresolved markers or ambiguous implementation instructions.
- Type consistency: LiveView actions are `:overview`, `:providers`, `:clients`, `:client_policies`, `:tokens`, `:scopes`, `:protocol_support`, `:users`, `:roles`, `:assignments`, and `:index` for audit.
