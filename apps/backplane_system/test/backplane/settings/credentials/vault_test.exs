defmodule Backplane.Settings.Credentials.VaultTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  setup do
    Backplane.Settings.TokenCache.clear()
    # Ensure the vault is refreshed after each test's DB setup
    Vault.reload()
    # Give the async cast time to process
    Process.sleep(50)
    :ok
  end

  describe "get/1" do
    test "returns nil for non-existent credential" do
      assert Vault.get("does-not-exist") == nil
    end

    test "returns credential struct after store" do
      {:ok, _} = Credentials.store("vault-test-key", "sk-abc123", "llm")

      cred = Vault.get("vault-test-key")
      assert cred != nil
      assert cred.name == "vault-test-key"
      assert cred.kind == "llm"
      # encrypted_value should be populated (but we don't expose plaintext)
      assert is_binary(cred.encrypted_value)
    end

    test "returns updated credential after rotate" do
      {:ok, _} = Credentials.store("vault-rotate", "old-secret", "llm")

      old_cred = Vault.get("vault-rotate")
      assert old_cred != nil

      {:ok, _} = Credentials.rotate("vault-rotate", "new-secret")

      new_cred = Vault.get("vault-rotate")
      assert new_cred != nil
      # The encrypted value should have changed
      assert new_cred.encrypted_value != old_cred.encrypted_value
    end
  end

  describe "list/0" do
    test "returns empty list when no credentials" do
      result = Vault.list()
      assert is_list(result)
    end

    test "returns credentials without encrypted values" do
      {:ok, _} = Credentials.store("vault-list-a", "secret-a", "llm")
      {:ok, _} = Credentials.store("vault-list-b", "secret-b", "upstream")

      listed = Vault.list()
      names = Enum.map(listed, & &1.name)
      assert "vault-list-a" in names
      assert "vault-list-b" in names

      # Verify no encrypted_value is exposed in the map
      for item <- listed do
        refute Map.has_key?(item, :encrypted_value)
        assert Map.has_key?(item, :id)
        assert Map.has_key?(item, :name)
        assert Map.has_key?(item, :kind)
        assert Map.has_key?(item, :metadata)
      end
    end

    test "returns credentials sorted by name" do
      {:ok, _} = Credentials.store("vault-z-cred", "s", "llm")
      {:ok, _} = Credentials.store("vault-a-cred", "s", "llm")
      {:ok, _} = Credentials.store("vault-m-cred", "s", "llm")

      listed = Vault.list()
      names = Enum.map(listed, & &1.name)
      vault_names = Enum.filter(names, &String.starts_with?(&1, "vault-"))
      assert vault_names == Enum.sort(vault_names)
    end
  end

  describe "exists?/1" do
    test "returns false for non-existent credential" do
      refute Vault.exists?("nope")
    end

    test "returns true after storing" do
      {:ok, _} = Credentials.store("vault-exists-test", "secret", "llm")
      assert Vault.exists?("vault-exists-test")
    end

    test "returns false after delete" do
      {:ok, _} = Credentials.store("vault-del-test", "secret", "llm")
      assert Vault.exists?("vault-del-test")

      :ok = Credentials.delete("vault-del-test")
      refute Vault.exists?("vault-del-test")
    end
  end

  describe "PubSub integration" do
    test "credential_changed notification reloads from DB" do
      {:ok, _} = Credentials.store("vault-pubsub", "secret1", "llm")

      cred = Vault.get("vault-pubsub")
      assert cred.kind == "llm"

      # Update metadata through Credentials context (which broadcasts)
      {:ok, _} = Credentials.update("vault-pubsub", %{kind: "upstream"})

      updated = Vault.get("vault-pubsub")
      assert updated.kind == "upstream"
    end

    test "credentials_reloaded triggers full reload" do
      {:ok, _} = Credentials.store("vault-reload-test", "s", "llm")
      assert Vault.exists?("vault-reload-test")

      # Broadcast a full reload
      Backplane.PubSubBroadcaster.broadcast_credentials_reloaded()
      # Full reload is async via PubSub, give it time
      Process.sleep(100)

      # Should still have the credential
      assert Vault.exists?("vault-reload-test")
    end
  end

  describe "direct ETS operations" do
    test "put/1 inserts a credential into the cache" do
      cred = %Backplane.Settings.Credential{
        id: Ecto.UUID.generate(),
        name: "direct-put-test",
        kind: "llm",
        encrypted_value: <<1, 2, 3>>,
        metadata: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert :ok = Vault.put(cred)
      assert Vault.get("direct-put-test") == cred
    end

    test "remove/1 deletes a credential from the cache" do
      {:ok, _} = Credentials.store("direct-remove-test", "secret", "llm")
      assert Vault.exists?("direct-remove-test")

      assert :ok = Vault.remove("direct-remove-test")
      refute Vault.exists?("direct-remove-test")
    end
  end

  describe "Credentials context reads from Vault" do
    test "fetch/1 returns decrypted value from vault" do
      {:ok, _} = Credentials.store("vault-fetch", "my-api-key-123", "llm")
      assert {:ok, "my-api-key-123"} = Credentials.fetch("vault-fetch")
    end

    test "fetch/1 returns :not_found for missing credential" do
      assert {:error, :not_found} = Credentials.fetch("vault-nonexistent")
    end

    test "fetch_with_meta/1 reads from vault" do
      {:ok, _} = Credentials.store("vault-meta", "key-456", "llm")

      assert {:ok, "key-456", %{auth_type: "api_key", extra_headers: []}} =
               Credentials.fetch_with_meta("vault-meta")
    end

    test "list/0 delegates to vault" do
      {:ok, _} = Credentials.store("vault-ctx-list", "s", "llm")

      listed = Credentials.list()
      names = Enum.map(listed, & &1.name)
      assert "vault-ctx-list" in names
    end

    test "exists?/1 delegates to vault" do
      {:ok, _} = Credentials.store("vault-ctx-exists", "s", "llm")

      assert Credentials.exists?("vault-ctx-exists")
      refute Credentials.exists?("vault-ctx-nope")
    end
  end
end
