defmodule Backplane.Accounts.AuthProviderTest do
  use Backplane.DataCase, async: true

  alias Backplane.Accounts
  alias Backplane.Accounts.AuthProvider

  describe "auth providers" do
    test "encrypts provider secrets and never returns plaintext in provider structs" do
      assert {:ok, provider} =
               Accounts.create_auth_provider(%{
                 slug: "google",
                 name: "Google",
                 kind: "oidc",
                 issuer: "https://accounts.google.com",
                 client_id: "client-id",
                 client_secret: "client-secret",
                 scopes: ["openid", "email", "profile"],
                 allowed_email_domains: ["example.com"]
               })

      assert %AuthProvider{} = provider
      assert provider.slug == "google"
      assert provider.client_secret == nil
      assert is_binary(provider.encrypted_client_secret)
      refute provider.encrypted_client_secret == "client-secret"
      assert {:ok, "client-secret"} = Accounts.fetch_auth_provider_secret(provider)

      assert [listed] = Accounts.list_auth_providers()
      assert listed.client_secret == nil
      assert listed.encrypted_client_secret == provider.encrypted_client_secret
    end

    test "rotates provider secret without changing provider metadata" do
      assert {:ok, provider} =
               Accounts.create_auth_provider(%{
                 slug: "github",
                 name: "GitHub",
                 kind: "oauth2",
                 authorization_url: "https://github.com/login/oauth/authorize",
                 token_url: "https://github.com/login/oauth/access_token",
                 userinfo_url: "https://api.github.com/user",
                 client_id: "github-client",
                 client_secret: "old-secret",
                 scopes: ["read:user", "user:email"]
               })

      old_encrypted = provider.encrypted_client_secret

      assert {:ok, rotated} = Accounts.rotate_auth_provider_secret(provider, "new-secret")
      assert rotated.id == provider.id
      assert rotated.slug == "github"
      assert rotated.encrypted_client_secret != old_encrypted
      assert rotated.client_secret == nil
      assert {:ok, "new-secret"} = Accounts.fetch_auth_provider_secret(rotated)
    end
  end
end
