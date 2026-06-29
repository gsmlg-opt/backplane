defmodule Backplane.Accounts.ResourceOwnersTest do
  use Backplane.DataCase, async: true

  alias Backplane.Accounts
  alias Backplane.Accounts.ResourceOwners
  alias Boruta.Oauth.ResourceOwner

  describe "boruta resource owner callbacks" do
    test "resolves a resource owner by stable user subject" do
      {:ok, %{user: user}} = provision_user()

      assert {:ok, %ResourceOwner{} = owner} = ResourceOwners.get_by(sub: user.id)
      assert owner.sub == user.id
      assert owner.username == "alice@example.com"
      assert owner.extra_claims["email"] == "alice@example.com"
    end

    test "rejects username lookup because email is not a stable unique subject" do
      assert {:error, "username lookup is not supported"} =
               ResourceOwners.get_by(username: "alice@example.com")
    end

    test "denies password grant checks" do
      {:ok, %{user: user}} = provision_user()
      {:ok, owner} = ResourceOwners.get_by(sub: user.id)

      assert {:error, "password grant is not supported"} =
               ResourceOwners.check_password(owner, "secret")
    end

    test "returns no authorized scopes until RBAC lands" do
      {:ok, %{user: user}} = provision_user()
      {:ok, owner} = ResourceOwners.get_by(sub: user.id)

      assert [] = ResourceOwners.authorized_scopes(owner)
    end

    test "returns non-secret identity claims" do
      {:ok, %{user: user}} = provision_user()
      {:ok, owner} = ResourceOwners.get_by(sub: user.id)

      assert %{"email" => "alice@example.com", "name" => "Alice Example"} =
               ResourceOwners.claims(owner, "openid email profile")
    end
  end

  defp provision_user do
    {:ok, provider} =
      Accounts.create_auth_provider(%{
        slug: "google",
        name: "Google",
        kind: "oidc",
        issuer: "https://accounts.google.com",
        client_id: "google-client",
        client_secret: "google-secret",
        scopes: ["openid", "email", "profile"]
      })

    Accounts.provision_federated_user(provider, %{
      "sub" => "google-sub-1",
      "email" => "alice@example.com",
      "name" => "Alice Example"
    })
  end
end
