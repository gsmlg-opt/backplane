defmodule Backplane.Admin.AuthSettingsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Auth

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
    {:ok, _event} =
      Auth.Audit.record("client.disabled", %{actor_type: "auth_admin", actor_id: "admin-1"}, %{
        target_type: "oauth_client",
        target_id: "client-1",
        severity: "warning",
        metadata: %{"client_name" => "GSMLG App Backend", "client_secret" => "hidden"}
      })

    {:ok, _view, html} = live(conn, "/auth/audit")

    assert html =~ "Auth Audit"
    assert html =~ "client.disabled"
    assert html =~ "warning"
    assert html =~ "oauth_client"
    assert html =~ "GSMLG App Backend"
    refute html =~ "client_secret"
    refute html =~ "Persistent Auth audit storage is not implemented yet"
  end

  test "OAuth clients page lists real clients and disables them", %{conn: conn} do
    client =
      oauth_client!(
        name: "GSMLG App Backend",
        redirect_uris: ["https://backend.gsmlg.test/auth/callback"],
        scopes: ["openid", "profile", "app:read"],
        confidential: true,
        pkce: true
      )

    {:ok, view, html} = live(conn, "/auth/oauth/clients")

    assert html =~ "OAuth Clients"
    assert html =~ "GSMLG App Backend"
    assert html =~ client.id
    assert html =~ "Confidential"
    assert html =~ "PKCE"
    assert html =~ "app:read"
    assert html =~ "https://backend.gsmlg.test/auth/callback"
    refute html =~ "List DCR-created clients"

    html =
      view
      |> element(~s(el-dm-button[phx-click="disable-client"][phx-value-id="#{client.id}"]))
      |> render_click()

    assert html =~ "Disabled"
    assert %{"disabled" => true} = Auth.OAuth.get_client(client.id).metadata
  end

  test "OAuth scopes page lists the real scope catalog", %{conn: conn} do
    scope!("gsmlg:read", label: "Read GSMLG data")

    {:ok, _view, html} = live(conn, "/auth/oauth/scopes")

    assert html =~ "OAuth Scopes"
    assert html =~ "gsmlg:read"
    assert html =~ "Read GSMLG data"
    assert html =~ "Public"
    refute html =~ "Scopes map OAuth grants"
  end

  test "OAuth tokens page lists issued tokens and revokes access", %{conn: conn} do
    user = auth_user!(email: "token-user@example.com", name: "Token User")

    client =
      oauth_client!(
        name: "GSMLG Umbrella",
        scopes: ["openid", "profile", "app:read"],
        confidential: false,
        pkce: true
      )

    {:ok, %{access_token: access_token, token: token}} =
      Auth.Tokens.issue_access_token(user, client, ["openid", "app:read"])

    {:ok, view, html} = live(conn, "/auth/oauth/tokens")

    assert html =~ "OAuth Tokens"
    assert html =~ "access_token"
    assert html =~ "GSMLG Umbrella"
    assert html =~ "token-user@example.com"
    assert html =~ "openid app:read"
    assert html =~ "Active"
    refute html =~ access_token
    refute html =~ "Token revocation belongs here"

    html =
      view
      |> element(~s(el-dm-button[phx-click="revoke-token"][phx-value-id="#{token.id}"]))
      |> render_click()

    assert html =~ "Revoked"
    assert {:error, :invalid_token} = Auth.Tokens.verify_access_token(access_token)
  end

  test "RBAC users page lists local auth users and disables them", %{conn: conn} do
    user = auth_user!(email: "admin@example.com", name: "Admin Example")

    {:ok, view, html} = live(conn, "/auth/rbac/users")

    assert html =~ "RBAC Users"
    assert html =~ "Admin Example"
    assert html =~ "admin@example.com"
    assert html =~ "Active"
    refute html =~ "Bootstrap Admin"

    html =
      view
      |> element(~s(el-dm-button[phx-click="disable-user"][phx-value-id="#{user.id}"]))
      |> render_click()

    assert html =~ "Inactive"
    refute Auth.Accounts.get_user(user.id).active
  end

  test "RBAC roles page lists real roles and granted scopes", %{conn: conn} do
    scope!("gsmlg:read")
    {:ok, role} = Auth.RBAC.create_role(%{name: "operator", label: "Operator"})
    {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, "gsmlg:read")

    {:ok, _view, html} = live(conn, "/auth/rbac/roles")

    assert html =~ "RBAC Roles"
    assert html =~ "Operator"
    assert html =~ "operator"
    assert html =~ "gsmlg:read"
    assert html =~ "Custom"
    refute html =~ "Built-in Roles"
  end

  test "RBAC assignments page lists user roles and effective scopes", %{conn: conn} do
    user = auth_user!(email: "assigned@example.com", name: "Assigned User")
    scope!("gsmlg:read")
    scope!("gsmlg:write")
    {:ok, role} = Auth.RBAC.create_role(%{name: "publisher", label: "Publisher"})
    {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, "gsmlg:read")
    {:ok, _role_scope} = Auth.RBAC.assign_role_scope(role, "gsmlg:write")
    {:ok, _user_role} = Auth.RBAC.assign_user_role(user, role)

    {:ok, _view, html} = live(conn, "/auth/rbac/assignments")

    assert html =~ "Role Assignments"
    assert html =~ "Assigned User"
    assert html =~ "assigned@example.com"
    assert html =~ "Publisher"
    assert html =~ "gsmlg:read"
    assert html =~ "gsmlg:write"
    refute html =~ "Operators assign roles"
  end

  defp auth_user!(attrs) do
    attrs =
      attrs
      |> Keyword.put_new(:email, "user-#{unique()}@example.com")
      |> Keyword.put_new(:name, "Test User")
      |> Map.new()

    {:ok, user} = Auth.Accounts.create_user(attrs)
    user
  end

  defp oauth_client!(attrs) do
    attrs =
      attrs
      |> Keyword.put_new(:name, "Test OAuth Client")
      |> Keyword.put_new(:redirect_uris, ["https://client.example.test/oauth/callback"])
      |> Keyword.put_new(:scopes, ["openid", "profile", "email"])
      |> Keyword.put_new(:confidential, true)
      |> Keyword.put_new(:pkce, true)
      |> Map.new()

    case Auth.OAuth.create_client(attrs) do
      {:ok, %{client: client}} -> Auth.OAuth.get_client(client.id)
      {:ok, client} -> Auth.OAuth.get_client(client.id)
    end
  end

  defp scope!(name, attrs \\ []) do
    Auth.OAuth.get_scope(name) ||
      create_scope!(name, attrs)
  end

  defp create_scope!(name, attrs) do
    attrs =
      attrs
      |> Keyword.put_new(:name, name)
      |> Keyword.put_new(:label, name)
      |> Keyword.put_new(:public, true)
      |> Map.new()

    {:ok, scope} = Auth.OAuth.create_scope(attrs)
    scope
  end

  defp unique, do: System.unique_integer([:positive])
end
