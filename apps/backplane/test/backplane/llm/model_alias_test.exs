defmodule Backplane.LLM.ModelAliasTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.ModelAlias
  alias Backplane.LLM.Provider

  @provider_attrs %{
    name: "alias-test-provider",
    api_type: :openai,
    api_url: "https://api.openai.com",
    api_key: "sk-test-key",
    models: ["gpt-4o", "gpt-4o-mini"]
  }

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup do
    {:ok, provider} = Provider.create(@provider_attrs)
    {:ok, provider: provider}
  end

  # ── create/1 ──────────────────────────────────────────────────────────────────

  describe "create/1" do
    test "valid attrs creates alias", %{provider: provider} do
      assert {:ok, model_alias} =
               ModelAlias.create(%{
                 alias: "fast",
                 model: "gpt-4o-mini",
                 provider_id: provider.id
               })

      assert model_alias.alias == "fast"
      assert model_alias.model == "gpt-4o-mini"
    end

    test "rejects duplicate alias", %{provider: provider} do
      {:ok, _} =
        ModelAlias.create(%{alias: "smart", model: "gpt-4o", provider_id: provider.id})

      assert {:error, changeset} =
               ModelAlias.create(%{alias: "smart", model: "gpt-4o-mini", provider_id: provider.id})

      assert %{alias: [_ | _]} = errors_on(changeset)
    end

    test "rejects slash in alias", %{provider: provider} do
      assert {:error, changeset} =
               ModelAlias.create(%{
                 alias: "some/alias",
                 model: "gpt-4o",
                 provider_id: provider.id
               })

      assert %{alias: [_ | _]} = errors_on(changeset)
    end

    test "rejects model not in provider's models list", %{provider: provider} do
      assert {:error, changeset} =
               ModelAlias.create(%{
                 alias: "unknown-model",
                 model: "claude-3-opus",
                 provider_id: provider.id
               })

      assert %{model: [_ | _]} = errors_on(changeset)
    end

    test "rejects deleted provider" do
      {:ok, other_provider} =
        Provider.create(%{
          name: "to-be-deleted",
          api_type: :anthropic,
          api_url: "https://api.anthropic.com",
          api_key: "sk-ant-key",
          models: ["claude-3-5-sonnet-20241022"]
        })

      {:ok, _} = Provider.soft_delete(other_provider)

      assert {:error, changeset} =
               ModelAlias.create(%{
                 alias: "deleted-alias",
                 model: "claude-3-5-sonnet-20241022",
                 provider_id: other_provider.id
               })

      assert %{provider_id: [_ | _]} = errors_on(changeset)
    end
  end

  # ── delete/1 ──────────────────────────────────────────────────────────────────

  describe "delete/1" do
    test "removes the alias", %{provider: provider} do
      {:ok, model_alias} =
        ModelAlias.create(%{alias: "to-delete", model: "gpt-4o", provider_id: provider.id})

      assert {:ok, _} = ModelAlias.delete(model_alias)
      assert ModelAlias.list() == []
    end
  end

  # ── list/0 ────────────────────────────────────────────────────────────────────

  describe "list/0" do
    test "returns all aliases with preloaded provider", %{provider: provider} do
      {:ok, _} = ModelAlias.create(%{alias: "a-fast", model: "gpt-4o-mini", provider_id: provider.id})
      {:ok, _} = ModelAlias.create(%{alias: "a-smart", model: "gpt-4o", provider_id: provider.id})

      aliases = ModelAlias.list()
      assert length(aliases) == 2
      assert hd(aliases).alias == "a-fast"
      assert %Provider{} = hd(aliases).provider
    end
  end

  # ── resolve/1 ─────────────────────────────────────────────────────────────────

  describe "resolve/1" do
    test "returns provider and model for valid alias", %{provider: provider} do
      {:ok, _} =
        ModelAlias.create(%{alias: "my-model", model: "gpt-4o", provider_id: provider.id})

      assert {:ok, resolved_provider, model} = ModelAlias.resolve("my-model")
      assert resolved_provider.id == provider.id
      assert model == "gpt-4o"
    end

    test "returns error for unknown alias" do
      assert {:error, :not_found} = ModelAlias.resolve("nonexistent")
    end

    test "returns error for disabled provider", %{provider: provider} do
      {:ok, _} =
        ModelAlias.create(%{alias: "disabled-alias", model: "gpt-4o", provider_id: provider.id})

      {:ok, _} = Provider.update(provider, %{enabled: false})

      assert {:error, :not_found} = ModelAlias.resolve("disabled-alias")
    end
  end
end
