defmodule Backplane.LLM.ProviderTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.Provider
  alias Backplane.Settings.Credentials

  @valid_attrs %{
    name: "test-provider",
    api_type: :anthropic,
    api_url: "https://api.anthropic.com",
    credential: "test-key",
    models: ["claude-3-5-sonnet-20241022"]
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup do
    Credentials.store("test-key", "sk-ant-test-value", "llm")
    :ok
  end

  # ── create/1 ──────────────────────────────────────────────────────────────────

  describe "create/1" do
    test "valid attrs inserts a provider" do
      assert {:ok, provider} = Provider.create(@valid_attrs)
      assert provider.name == "test-provider"
      assert provider.api_type == :anthropic
      assert provider.credential == "test-key"
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

    test "rejects missing credential" do
      attrs = Map.delete(@valid_attrs, :credential)
      assert {:error, changeset} = Provider.create(attrs)
      assert %{credential: [_ | _]} = errors_on(changeset)
    end

    test "rejects credential that does not exist in store" do
      attrs = %{@valid_attrs | name: "bad-cred", credential: "nonexistent-cred"}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{credential: [msg]} = errors_on(changeset)
      assert msg =~ "not found"
    end

    test "does not accept api_key parameter" do
      attrs = Map.put(@valid_attrs, :api_key, "sk-ant-should-not-work")
      # api_key is not a field, so it's silently ignored; the provider still creates fine
      assert {:ok, provider} = Provider.create(attrs)
      refute Map.has_key?(Map.from_struct(provider), :api_key)
    end

    test "rejects empty models list" do
      attrs = %{@valid_attrs | name: "empty-models", models: []}
      assert {:error, changeset} = Provider.create(attrs)
      assert %{models: [_ | _]} = errors_on(changeset)
    end

    test "rejects duplicate name" do
      assert {:ok, _} = Provider.create(@valid_attrs)

      assert {:error, changeset} =
               Provider.create(%{@valid_attrs | name: "test-provider"})

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

    test "updates credential reference", %{provider: provider} do
      Credentials.store("other-key", "sk-other-value", "llm")

      assert {:ok, updated} = Provider.update(provider, %{credential: "other-key"})
      assert updated.credential == "other-key"
    end

    test "rejects update to nonexistent credential", %{provider: provider} do
      assert {:error, changeset} = Provider.update(provider, %{credential: "does-not-exist"})
      assert %{credential: [_ | _]} = errors_on(changeset)
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

      assert {:ok, new_provider} = Provider.create(@valid_attrs)
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
  end
end
