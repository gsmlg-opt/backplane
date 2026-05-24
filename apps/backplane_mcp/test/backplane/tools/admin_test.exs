defmodule Backplane.Tools.AdminTest do
  use Backplane.DataCase, async: true

  import Backplane.Fixtures

  alias Backplane.Tools.Admin
  alias Backplane.Clients

  describe "admin::list-clients" do
    test "returns all clients" do
      {_c1, _token1} = insert_client(name: "client-a")
      {_c2, _token2} = insert_client(name: "client-b")

      assert {:ok, %{clients: clients}} = Admin.call(%{"_handler" => "list_clients"})
      assert length(clients) == 2

      names = Enum.map(clients, & &1.name) |> Enum.sort()
      assert names == ["client-a", "client-b"]
    end

    test "excludes token_hash from response" do
      {_c, _token} = insert_client(name: "client-a")

      {:ok, %{clients: [client]}} = Admin.call(%{"_handler" => "list_clients"})

      assert Map.has_key?(client, :id)
      assert Map.has_key?(client, :name)
      assert Map.has_key?(client, :scopes)
      assert Map.has_key?(client, :active)
      refute Map.has_key?(client, :token_hash)
    end
  end

  describe "admin::upsert-client" do
    test "creates new client with hashed token" do
      assert {:ok, result} =
               Admin.call(%{
                 "_handler" => "upsert_client",
                 "name" => "new-client",
                 "token" => "secret",
                 "scopes" => ["docs::*"]
               })

      assert result.name == "new-client"
      assert result.scopes == ["docs::*"]
      assert result.active == true
      assert is_binary(result.id)

      client = Clients.get_client_by_name("new-client")
      assert client != nil
      assert Bcrypt.verify_pass("secret", client.token_hash)
    end

    test "updates existing client scopes" do
      {:ok, _created} =
        Admin.call(%{
          "_handler" => "upsert_client",
          "name" => "existing",
          "token" => "original-token",
          "scopes" => ["docs::*"]
        })

      {:ok, updated} =
        Admin.call(%{
          "_handler" => "upsert_client",
          "name" => "existing",
          "scopes" => ["git::*", "docs::*"]
        })

      assert updated.name == "existing"
      assert updated.scopes == ["git::*", "docs::*"]
    end

    test "rotates token when provided on update" do
      {:ok, _created} =
        Admin.call(%{
          "_handler" => "upsert_client",
          "name" => "rotate-me",
          "token" => "old-token",
          "scopes" => ["*"]
        })

      {:ok, _updated} =
        Admin.call(%{
          "_handler" => "upsert_client",
          "name" => "rotate-me",
          "token" => "new-token",
          "scopes" => ["*"]
        })

      client = Clients.get_client_by_name("rotate-me")
      refute Bcrypt.verify_pass("old-token", client.token_hash)
      assert Bcrypt.verify_pass("new-token", client.token_hash)
    end

    test "returns error when token missing on create" do
      assert {:error, _reason} =
               Admin.call(%{
                 "_handler" => "upsert_client",
                 "name" => "no-token",
                 "scopes" => ["docs::*"]
               })
    end
  end
end
