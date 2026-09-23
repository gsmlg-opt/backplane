defmodule Backplane.LLM.Google.ModelDiscoveryTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{
    ModelDiscovery,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :llm_model_discovery_req_options)

    Application.put_env(:backplane, :llm_model_discovery_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane, :llm_model_discovery_req_options, previous),
        else: Application.delete_env(:backplane, :llm_model_discovery_req_options)
    end)

    {:ok, _} = Credentials.store("google-discovery-key", "upstream-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "google-discovery",
        preset_key: "google-gemini-developer",
        credential: "google-discovery-key"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :google,
        native_protocols: [:google_generate_content],
        base_url: "https://generativelanguage.example.test/v1beta",
        model_discovery_path: "/models"
      })

    %{provider: Provider.get(provider.id), api: api}
  end

  test "follows every Google page and stores normalized resources with raw metadata", %{
    provider: provider,
    api: api
  } do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["upstream-secret"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      send(owner, {:page, conn.query_string})

      case URI.decode_query(conn.query_string) do
        %{"pageToken" => "page-2"} ->
          json(conn, %{
            "models" => [google_model("models/gemini-2.5-pro", "Gemini 2.5 Pro")]
          })

        %{} ->
          json(conn, %{
            "models" => [google_model("models/gemini-2.5-flash", "Gemini 2.5 Flash")],
            "nextPageToken" => "page-2"
          })
      end
    end)

    assert %{discovered: 2, created: 2, errors: []} =
             ModelDiscovery.reload_api(provider, api)

    assert_received {:page, ""}
    assert_received {:page, "pageToken=page-2"}

    model = ProviderModel.get_by_provider_and_model(provider.id, "gemini-2.5-pro")
    assert model.display_name == "Gemini 2.5 Pro"
    assert model.metadata["name"] == "models/gemini-2.5-pro"
    assert model.metadata["inputTokenLimit"] == 1_048_576
    assert model.metadata["outputTokenLimit"] == 65_536
    assert model.metadata["supportedGenerationMethods"] == ["generateContent", "countTokens"]
    assert model.metadata["provenance"] == "google_models_api"
    assert model.metadata["api_version"] == "v1beta"
    assert model.metadata["provider_api_id"] == api.id
  end

  test "drops a late discovery result after the API is disabled", %{provider: provider, api: api} do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _api} = ProviderApi.update(ProviderApi.get(api.id), %{enabled: false})
      json(conn, %{"models" => [google_model("models/late-model", "Late model")]})
    end)

    assert %{discovered: 0, errors: [error]} = ModelDiscovery.reload_api(provider, api)
    assert error =~ "discovery_configuration_changed"
    refute ProviderModel.get_by_provider_and_model(provider.id, "late-model")
  end

  test "drops a late discovery result after the credential generation changes", %{
    provider: provider,
    api: api
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _credential} =
        Credentials.store("google-discovery-key", "rotated-upstream-secret", "llm")

      json(conn, %{"models" => [google_model("models/stale-key-model", "Stale key model")]})
    end)

    assert %{discovered: 0, errors: [error]} = ModelDiscovery.reload_api(provider, api)
    assert error =~ "discovery_configuration_changed"
    refute ProviderModel.get_by_provider_and_model(provider.id, "stale-key-model")
  end

  test "does not recreate a model surface deleted while pages are in flight", %{
    provider: provider,
    api: api
  } do
    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "operator-removed",
        source: :manual
      })

    {:ok, surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id
      })

    provider = Provider.get(provider.id)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _surface} = Repo.delete(surface)

      json(conn, %{
        "models" => [google_model("models/operator-removed", "Operator removed")]
      })
    end)

    assert %{discovered: 0, created: 0, updated: 0, errors: [error]} =
             ModelDiscovery.reload_api(provider, api)

    assert error =~ "discovery_configuration_changed"
    refute ProviderModelSurface.get_by_model_and_api(model.id, api.id)
  end

  test "does not publish a partial catalog when a later page fails", %{
    provider: provider,
    api: api
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      case URI.decode_query(conn.query_string) do
        %{"pageToken" => "broken"} ->
          Plug.Conn.send_resp(conn, 503, "unavailable")

        %{} ->
          json(conn, %{
            "models" => [google_model("models/partial", "Partial")],
            "nextPageToken" => "broken"
          })
      end
    end)

    assert %{discovered: 0, errors: [error]} = ModelDiscovery.reload_api(provider, api)
    assert error =~ "HTTP 503"
    refute ProviderModel.get_by_provider_and_model(provider.id, "partial")
  end

  defp google_model(name, display_name) do
    %{
      "name" => name,
      "displayName" => display_name,
      "inputTokenLimit" => 1_048_576,
      "outputTokenLimit" => 65_536,
      "supportedGenerationMethods" => ["generateContent", "countTokens"]
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
