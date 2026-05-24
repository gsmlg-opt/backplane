defmodule Backplane.ClientsTest do
  use Backplane.DataCase, async: true

  import Backplane.Fixtures

  alias Backplane.Clients

  describe "verify_token/1" do
    test "returns {:ok, client} for valid token" do
      {client, token} = insert_client(token: "my-secret-token")

      assert {:ok, verified} = Clients.verify_token(token)
      assert verified.id == client.id
    end

    test "returns :error for invalid token" do
      insert_client(token: "my-secret-token")

      assert :error = Clients.verify_token("wrong-token")
    end

    test "returns :error for inactive client token" do
      {_client, token} = insert_client(active: false, token: "inactive-token")

      assert :error = Clients.verify_token(token)
    end

    test "updates last_seen_at on successful verify" do
      {client, token} = insert_client(token: "my-secret-token")
      assert is_nil(client.last_seen_at)

      assert {:ok, _verified} = Clients.verify_token(token)

      Process.sleep(100)

      reloaded = Backplane.Repo.get!(Backplane.Clients.Client, client.id)
      assert reloaded.last_seen_at != nil
    end
  end

  describe "scope_matches?/2" do
    test ~s("*" matches any tool name) do
      assert Clients.scope_matches?(["*"], "docs::query-docs")
    end

    test ~s("docs::*" matches "docs::query-docs") do
      assert Clients.scope_matches?(["docs::*"], "docs::query-docs")
    end

    test ~s("docs::*" does not match "git::repo-tree") do
      refute Clients.scope_matches?(["docs::*"], "git::repo-tree")
    end

    test ~s("docs::query-docs" matches exactly) do
      assert Clients.scope_matches?(["docs::query-docs"], "docs::query-docs")
    end

    test ~s("docs::query-docs" does not match "docs::resolve-project") do
      refute Clients.scope_matches?(["docs::query-docs"], "docs::resolve-project")
    end

    test "multiple scopes: match if any scope matches" do
      scopes = ["docs::*", "git::repo-tree"]

      assert Clients.scope_matches?(scopes, "docs::query-docs")
      assert Clients.scope_matches?(scopes, "git::repo-tree")
      refute Clients.scope_matches?(scopes, "git::list-repos")
    end
  end

  describe "upsert_from_config/1" do
    test "creates new client from config" do
      assert {:ok, client} =
               Clients.upsert_from_config(%{name: "test", token: "tok", scopes: ["*"]})

      assert client.name == "test"
      assert client.scopes == ["*"]
    end

    test "updates existing client scopes on re-boot" do
      {:ok, original} =
        Clients.upsert_from_config(%{name: "test", token: "tok", scopes: ["*"]})

      {:ok, updated} =
        Clients.upsert_from_config(%{name: "test", token: "tok", scopes: ["docs::*"]})

      assert updated.id == original.id
      assert updated.scopes == ["docs::*"]
    end
  end
end
