defmodule Backplane.Tools.AdminTest do
  use BackplaneMcp.DataCase, async: false

  alias Backplane.Clients
  alias Backplane.Tools.Admin

  test "creates a client with a server-issued token and lists metadata only" do
    assert {:ok, result} = upsert("new-client", %{"scopes" => ["docs::*"]})
    assert result.name == "new-client"
    assert result.scopes == ["docs::*"]
    assert result.active
    assert String.starts_with?(result.token, "bp2_")
    assert byte_size(result.token) == 47
    assert {:ok, client} = Clients.verify_token(result.token)
    assert client.id == result.id

    assert {:ok, %{clients: [listed]}} = Admin.call(%{"_handler" => "list_clients"})
    refute Map.has_key?(listed, :token)
    refute Map.has_key?(listed, :token_digest)
    refute Map.has_key?(listed, :token_hash)
    refute inspect(listed) =~ result.token
  end

  test "ordinary updates preserve the token and do not return it again" do
    assert {:ok, created} = upsert("existing")
    assert {:ok, updated} = upsert("existing", %{"scopes" => ["git::*"]})
    assert updated.id == created.id
    assert updated.scopes == ["git::*"]
    refute Map.has_key?(updated, :token)
    assert {:ok, client} = Clients.verify_token(created.token)
    assert client.scopes == ["git::*"]
  end

  test "only explicit rotation replaces the credential" do
    assert {:ok, created} = upsert("rotate-me")
    assert {:ok, updated} = upsert("rotate-me", %{"rotate_token" => true})
    assert updated.id == created.id
    assert updated.token != created.token
    assert :error = Clients.verify_token(created.token)
    assert {:ok, client} = Clients.verify_token(updated.token)
    assert client.id == created.id
  end

  test "rejects custom or internal credential inputs without changing or disclosing them" do
    assert {:ok, created} = upsert("protected")

    for field <- ["token", "token_hash", "token_digest", "scheme", "credential_scheme"] do
      secret = "must-not-appear-#{field}"
      assert {:error, reason} = upsert("protected", %{field => secret})
      refute inspect(reason) =~ secret
      assert {:ok, _client} = Clients.verify_token(created.token)
    end
  end

  test "invalid rotation flags cannot rotate or create a client" do
    for value <- ["true", 1, nil] do
      assert {:error, _reason} = upsert("invalid", %{"rotate_token" => value})
      assert Clients.get_client_by_name("invalid") == nil
    end
  end

  defp upsert(name, attrs \\ %{}) do
    Admin.call(
      Map.merge(%{"_handler" => "upsert_client", "name" => name, "scopes" => ["*"]}, attrs)
    )
  end
end
