defmodule Backplane.Admin.AuthSettingsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Accounts

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
    {:ok, _view, html} = live(conn, "/auth/audit")

    assert html =~ "Auth Audit"
    assert html =~ "Login events"
    assert html =~ "Token events"
    assert html =~ "Role events"
  end

  test "OAuth settings lists inbound identity providers", %{conn: conn} do
    {:ok, _provider} =
      Accounts.create_auth_provider(%{
        slug: "google",
        name: "Google Workspace",
        kind: "oidc",
        issuer: "https://accounts.google.com",
        client_id: "google-client",
        client_secret: "google-secret",
        scopes: ["openid", "email", "profile"],
        allowed_email_domains: ["example.com"]
      })

    {:ok, _view, html} = live(conn, "/auth/oauth/providers")

    assert html =~ "OAuth Providers"
    assert html =~ "Google Workspace"
    assert html =~ "google"
    assert html =~ "OIDC"
    assert html =~ "example.com"
  end

  test "RBAC settings lists human users and bootstrap admin status", %{conn: conn} do
    {:ok, provider} =
      Accounts.create_auth_provider(%{
        slug: "github",
        name: "GitHub",
        kind: "oauth2",
        authorization_url: "https://github.com/login/oauth/authorize",
        token_url: "https://github.com/login/oauth/access_token",
        userinfo_url: "https://api.github.com/user",
        client_id: "github-client",
        client_secret: "github-secret",
        scopes: ["read:user", "user:email"]
      })

    {:ok, %{user: user}} =
      Accounts.provision_federated_user(provider, %{
        "sub" => "github-user-1",
        "email" => "admin@example.com",
        "name" => "Admin Example"
      })

    old_emails = Application.get_env(:backplane, :bootstrap_admin_emails)
    Application.put_env(:backplane, :bootstrap_admin_emails, [user.email])

    on_exit(fn ->
      if is_nil(old_emails) do
        Application.delete_env(:backplane, :bootstrap_admin_emails)
      else
        Application.put_env(:backplane, :bootstrap_admin_emails, old_emails)
      end
    end)

    {:ok, _view, html} = live(conn, "/auth/rbac/users")

    assert html =~ "RBAC Users"
    assert html =~ "Admin Example"
    assert html =~ "admin@example.com"
    assert html =~ "Bootstrap Admin"
  end
end
