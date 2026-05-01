defmodule Backplane.LLM.ProviderTest do
  use Backplane.DataCase, async: true

  alias Backplane.LLM.{
    AutoModel,
    AutoModelRoute,
    AutoModelTarget,
    ModelDiscovery,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Settings.Credentials

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp credential_name do
    "test-key-#{System.unique_integer([:positive])}"
  end

  defp valid_provider_attrs(credential) do
    %{
      name: "test-provider-#{System.unique_integer([:positive])}",
      credential: credential,
      preset_key: "deepseek",
      default_headers: %{"x-provider" => "test"},
      rpm_limit: 100
    }
  end

  defp create_provider(attrs \\ %{}) do
    credential = Map.get_lazy(attrs, :credential, fn -> credential_name() end)
    Credentials.store(credential, "sk-test-value", "llm")

    attrs =
      credential
      |> valid_provider_attrs()
      |> Map.merge(attrs)

    {:ok, provider} = Provider.create(attrs)
    provider
  end

  describe "Provider.create/1" do
    test "valid attrs inserts a provider without api_type or provider-level models" do
      credential = credential_name()
      Credentials.store(credential, "sk-test-value", "llm")

      assert {:ok, provider} = Provider.create(valid_provider_attrs(credential))
      assert provider.name =~ "test-provider"
      assert provider.credential == credential
      assert provider.preset_key == "deepseek"
      assert provider.default_headers == %{"x-provider" => "test"}
      assert provider.rpm_limit == 100
      refute Map.has_key?(Map.from_struct(provider), :api_type)
    end

    test "rejects missing name" do
      credential = credential_name()
      Credentials.store(credential, "sk-test-value", "llm")

      attrs =
        credential
        |> valid_provider_attrs()
        |> Map.delete(:name)

      assert {:error, changeset} = Provider.create(attrs)
      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "rejects invalid names" do
      credential = credential_name()
      Credentials.store(credential, "sk-test-value", "llm")

      assert {:error, changeset} =
               credential
               |> valid_provider_attrs()
               |> Map.put(:name, "BadName")
               |> Provider.create()

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "rejects missing credential" do
      attrs =
        "missing"
        |> valid_provider_attrs()
        |> Map.delete(:credential)

      assert {:error, changeset} = Provider.create(attrs)
      assert %{credential: [_ | _]} = errors_on(changeset)
    end

    test "rejects credential that does not exist" do
      attrs = valid_provider_attrs("does-not-exist")
      assert {:error, changeset} = Provider.create(attrs)
      assert %{credential: [message]} = errors_on(changeset)
      assert message =~ "not found"
    end

    test "rejects non-positive rpm_limit" do
      credential = credential_name()
      Credentials.store(credential, "sk-test-value", "llm")

      assert {:error, changeset} =
               credential
               |> valid_provider_attrs()
               |> Map.put(:rpm_limit, 0)
               |> Provider.create()

      assert %{rpm_limit: [_ | _]} = errors_on(changeset)
    end
  end

  describe "Provider.update/2 and soft_delete/1" do
    test "updates provider fields" do
      provider = create_provider()
      credential = credential_name()
      Credentials.store(credential, "sk-other-value", "llm")

      assert {:ok, updated} =
               Provider.update(provider, %{
                 credential: credential,
                 default_headers: %{"x-new" => "1"},
                 rpm_limit: 200
               })

      assert updated.credential == credential
      assert updated.default_headers == %{"x-new" => "1"}
      assert updated.rpm_limit == 200
    end

    test "soft delete disables and excludes provider from list" do
      provider = create_provider()

      assert {:ok, deleted} = Provider.soft_delete(provider)
      assert deleted.enabled == false
      assert %DateTime{} = deleted.deleted_at
      refute Enum.any?(Provider.list(), &(&1.id == provider.id))
    end
  end

  describe "ProviderApi" do
    test "creates independent API surfaces for one provider" do
      provider = create_provider()

      assert {:ok, openai} =
               ProviderApi.create(%{
                 provider_id: provider.id,
                 api_surface: :openai,
                 base_url: "https://api.deepseek.com/",
                 model_discovery_path: "/models"
               })

      assert {:ok, anthropic} =
               ProviderApi.create(%{
                 provider_id: provider.id,
                 api_surface: :anthropic,
                 base_url: "https://api.deepseek.com/anthropic",
                 model_discovery_path: "/v1/models"
               })

      assert openai.base_url == "https://api.deepseek.com"
      assert anthropic.base_url == "https://api.deepseek.com/anthropic"
    end

    test "rejects http for non-localhost base URL" do
      provider = create_provider()

      assert {:error, changeset} =
               ProviderApi.create(%{
                 provider_id: provider.id,
                 api_surface: :openai,
                 base_url: "http://api.example.com"
               })

      assert %{base_url: [_ | _]} = errors_on(changeset)
    end

    test "allows http for localhost base URL" do
      provider = create_provider()

      assert {:ok, api} =
               ProviderApi.create(%{
                 provider_id: provider.id,
                 api_surface: :openai,
                 base_url: "http://localhost:11434"
               })

      assert api.base_url == "http://localhost:11434"
    end

    test "enforces one API surface per provider" do
      provider = create_provider()

      attrs = %{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.deepseek.com"
      }

      assert {:ok, _api} = ProviderApi.create(attrs)
      assert {:error, changeset} = ProviderApi.create(attrs)
      assert %{provider_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "ProviderModel and ProviderModelSurface" do
    test "creates provider models and per-surface enablement" do
      provider = create_provider()

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://api.deepseek.com"
        })

      assert {:ok, model} =
               ProviderModel.create(%{
                 provider_id: provider.id,
                 model: "deepseek-v4-flash",
                 source: :discovered,
                 display_name: "DeepSeek V4 Flash"
               })

      assert {:ok, surface} =
               ProviderModelSurface.create(%{
                 provider_model_id: model.id,
                 provider_api_id: api.id,
                 enabled: true
               })

      assert surface.enabled
    end

    test "rejects model surface when API belongs to another provider" do
      provider = create_provider()
      other_provider = create_provider()

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: other_provider.id,
          api_surface: :openai,
          base_url: "https://api.deepseek.com"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "deepseek-v4-flash",
          source: :manual
        })

      assert {:error, changeset} =
               ProviderModelSurface.create(%{
                 provider_model_id: model.id,
                 provider_api_id: api.id
               })

      assert %{provider_api_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "ModelDiscovery.reload_provider/1" do
    setup do
      previous = Application.get_env(:backplane, :llm_model_discovery_req_options)

      Application.put_env(:backplane, :llm_model_discovery_req_options,
        plug: {Req.Test, __MODULE__}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:backplane, :llm_model_discovery_req_options, previous)
        else
          Application.delete_env(:backplane, :llm_model_discovery_req_options)
        end
      end)

      :ok
    end

    test "reloads models from provider API discovery endpoint" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/models"
        assert ["Bearer sk-test-value"] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "model-a"},
              %{"id" => "model-b"}
            ]
          })
        )
      end)

      provider = create_provider()

      {:ok, _api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://provider.test",
          model_discovery_path: "/models"
        })

      provider = Provider.get(provider.id)

      assert %{discovered: 2, created: 2, updated: 0, errors: []} =
               ModelDiscovery.reload_provider(provider)

      assert [%{model: "model-a"}, %{model: "model-b"}] =
               ProviderModel.list_for_provider(provider.id)

      assert [%{last_discovered_at: %DateTime{}}] = ProviderApi.list_for_provider(provider.id)
    end
  end

  describe "seeded auto models" do
    test "seeds fast, smart, and expert with openai and anthropic routes" do
      models = AutoModel.list()
      assert [%{name: "expert"}, %{name: "fast"}, %{name: "smart"}] = models

      for auto_model <- models do
        routes = Enum.sort_by(auto_model.routes, &to_string(&1.api_surface))
        assert [%{api_surface: :anthropic}, %{api_surface: :openai}] = routes
      end
    end

    test "auto model targets must match route API surface" do
      provider = create_provider()

      {:ok, openai_api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://api.deepseek.com"
        })

      {:ok, anthropic_api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :anthropic,
          base_url: "https://api.deepseek.com/anthropic"
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "deepseek-v4-flash",
          source: :manual
        })

      {:ok, openai_surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: openai_api.id
        })

      {:ok, anthropic_surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: anthropic_api.id
        })

      openai_route = AutoModelRoute.get_by_model_and_surface("fast", :openai)

      assert {:ok, _target} =
               AutoModelTarget.create(%{
                 auto_model_route_id: openai_route.id,
                 provider_model_surface_id: openai_surface.id,
                 priority: 0
               })

      assert {:error, changeset} =
               AutoModelTarget.create(%{
                 auto_model_route_id: openai_route.id,
                 provider_model_surface_id: anthropic_surface.id,
                 priority: 1
               })

      assert %{provider_model_surface_id: [_ | _]} = errors_on(changeset)
    end
  end
end
