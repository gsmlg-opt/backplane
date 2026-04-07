defmodule Backplane.LLM.ProviderTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.Provider

  @valid_attrs %{
    name: "test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    api_key: "sk-ant-test-key",
    models: ["claude-3-5-sonnet-20241022"]
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── create/1 ──────────────────────────────────────────────────────────────────

  describe "create/1" do
    test "valid attrs inserts a provider" do
      assert {:ok, provider} = Provider.create(@valid_attrs)
      assert provider.name == "test-provider"
      assert provider.api_type == :anthropic
    end

    test "encrypts api_key into api_key_encrypted" do
      assert {:ok, provider} = Provider.create(@valid_attrs)
      assert is_binary(provider.api_key_encrypted)
      assert {:ok, "sk-ant-test-key"} = Provider.decrypt_api_key(provider)
    end

    test "rejects missing name" do
      attrs = Map.delete(@valid_attrs, :name)
      assert {:error, changeset} = Provider.create(attrs)
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "rejects invalid name chars (uppercase)" do
      attrs = %{@valid_attrs | name: "Test-Provider"}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "rejects invalid name chars (starts with hyphen)" do
      attrs = %{@valid_attrs | name: "-test"}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "rejects missing api_type" do
      attrs = Map.delete(@valid_attrs, :api_type)
      assert {:error, changeset} = Provider.create(attrs)
      assert %{api_type: [_ | _]} = errors_on(changeset)
    end

    test "rejects invalid api_type" do
      attrs = %{@valid_attrs | api_type: :unknown_type}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{api_type: [_ | _]} = errors_on(changeset)
    end

    test "rejects missing api_url" do
      attrs = Map.delete(@valid_attrs, :api_url)
      assert {:error, changeset} = Provider.create(attrs)
      assert %{api_url: [_ | _]} = errors_on(changeset)
    end

    test "rejects http:// for non-localhost" do
      attrs = %{@valid_attrs | name: "remote-http", api_url: "http://api.example.com"}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{api_url: [_ | _]} = errors_on(changeset)
    end

    test "allows http:// for localhost" do
      attrs = %{@valid_attrs | name: "local-provider", api_url: "http://localhost:8080"}
      assert {:ok, provider} = Provider.create(attrs)
      assert provider.api_url == "http://localhost:8080"
    end

    test "allows http:// for 127.0.0.1" do
      attrs = %{@valid_attrs | name: "loopback-provider", api_url: "http://127.0.0.1:11434"}
      assert {:ok, provider} = Provider.create(attrs)
      assert provider.api_url == "http://127.0.0.1:11434"
    end

    test "rejects missing api_key on insert" do
      attrs = Map.delete(@valid_attrs, :api_key)
      assert {:error, changeset} = Provider.create(attrs)
      assert %{api_key: [_ | _]} = errors_on(changeset)
    end

    test "rejects empty models list" do
      attrs = %{@valid_attrs | name: "empty-models", models: []}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{models: [_ | _]} = errors_on(changeset)
    end

    test "rejects duplicate name" do
      assert {:ok, _} = Provider.create(@valid_attrs)

      assert {:error, changeset} =
               Provider.create(%{@valid_attrs | api_key: "sk-ant-other-key"})

      assert %{name: [_ | _]} = errors_on(changeset)
    end
  end

  # ── update/2 ──────────────────────────────────────────────────────────────────

  describe "update/2" do
    setup do
      {:ok, provider} = Provider.create(@valid_attrs)
      {:ok, provider: provider}
    end

    test "updates non-key fields", %{provider: provider} do
      assert {:ok, updated} =
               Provider.update(provider, %{models: ["claude-3-haiku-20240307"], rpm_limit: 100})

      assert updated.models == ["claude-3-haiku-20240307"]
      assert updated.rpm_limit == 100
    end

    test "re-encrypts on key change", %{provider: provider} do
      old_encrypted = provider.api_key_encrypted

      assert {:ok, updated} = Provider.update(provider, %{api_key: "sk-ant-new-key"})

      assert updated.api_key_encrypted != old_encrypted
      assert {:ok, "sk-ant-new-key"} = Provider.decrypt_api_key(updated)
    end

    test "preserves existing key when api_key not provided", %{provider: provider} do
      old_encrypted = provider.api_key_encrypted

      assert {:ok, updated} = Provider.update(provider, %{rpm_limit: 60})

      assert updated.api_key_encrypted == old_encrypted
    end
  end

  # ── soft_delete/1 ─────────────────────────────────────────────────────────────

  describe "soft_delete/1" do
    setup do
      {:ok, provider} = Provider.create(@valid_attrs)
      {:ok, provider: provider}
    end

    test "sets deleted_at and enabled=false", %{provider: provider} do
      assert {:ok, deleted} = Provider.soft_delete(provider)
      assert deleted.enabled == false
      assert %DateTime{} = deleted.deleted_at
    end

    test "hard-deletes aliases", %{provider: provider} do
      alias Backplane.LLM.ModelAlias

      {:ok, _} =
        ModelAlias.create(%{
          alias: "fast",
          model: "claude-3-5-sonnet-20241022",
          provider_id: provider.id
        })

      assert {:ok, _} = Provider.soft_delete(provider)

      assert ModelAlias.list() == []
    end

    test "releases name for reuse after soft-delete", %{provider: provider} do
      assert {:ok, _} = Provider.soft_delete(provider)

      assert {:ok, new_provider} =
               Provider.create(%{@valid_attrs | api_key: "sk-ant-new-key"})

      assert new_provider.name == "test-provider"
    end

    test "excluded from list after soft-delete", %{provider: provider} do
      assert {:ok, _} = Provider.soft_delete(provider)
      assert Provider.list() == []
    end
  end

  # ── list/0 ────────────────────────────────────────────────────────────────────

  describe "list/0" do
    test "returns active providers" do
      {:ok, _} = Provider.create(@valid_attrs)
      providers = Provider.list()
      assert length(providers) == 1
      assert hd(providers).name == "test-provider"
    end

    test "excludes deleted providers" do
      {:ok, provider} = Provider.create(@valid_attrs)
      {:ok, _} = Provider.soft_delete(provider)
      assert Provider.list() == []
    end

    test "does not expose raw encrypted key in list" do
      {:ok, _} = Provider.create(@valid_attrs)
      [provider] = Provider.list()
      # api_key (virtual) should be nil; api_key_encrypted is binary, not plain text
      assert is_nil(provider.api_key)
      assert is_binary(provider.api_key_encrypted)
      refute provider.api_key_encrypted == "sk-ant-test-key"
    end
  end
end
