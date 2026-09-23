defmodule Backplane.LLM.Antigravity.ModelDiscoveryTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{ModelDiscovery, Provider, ProviderApi, ProviderModel}
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

    {:ok, _} =
      Credentials.store_device_token("antigravity-discovery-oauth", "google_oauth", %{
        "access_token" => "oauth-discovery-secret",
        "refresh_token" => "refresh-token",
        "expires_at" => System.system_time(:millisecond) + 3_600_000
      })

    {:ok, provider} =
      Provider.create(%{
        name: "antigravity-discovery",
        preset_key: "google-antigravity",
        credential: "antigravity-discovery-oauth"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :antigravity,
        base_url: "https://cloudcode.example.test",
        model_discovery_enabled: true,
        model_discovery_path: "/v1internal:fetchAvailableModels",
        backend_config: %{"project_id" => "managed-project", "client_version" => "1.0"}
      })

    %{provider: Provider.get(provider.id), api: api}
  end

  test "posts native discovery and preserves model metadata and quota", %{
    provider: provider,
    api: api
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1internal:fetchAvailableModels"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer oauth-discovery-secret"]
      assert Plug.Conn.get_req_header(conn, "x-client-version") == ["1.0"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"project" => "managed-project"}

      json(conn, %{
        "models" => %{
          "gemini-3-pro" => %{
            "displayName" => "Gemini 3 Pro",
            "quotaInfo" => %{"remainingFraction" => 0.75},
            "unknownNativeField" => %{"keep" => true}
          }
        }
      })
    end)

    assert %{discovered: 1, created: 1, errors: []} = ModelDiscovery.reload_api(provider, api)

    model = ProviderModel.get_by_provider_and_model(provider.id, "gemini-3-pro")
    assert model.display_name == "Gemini 3 Pro"
    assert model.metadata["quotaInfo"] == %{"remainingFraction" => 0.75}
    assert model.metadata["unknownNativeField"] == %{"keep" => true}
    assert model.metadata["provenance"] == "antigravity_fetch_available_models"
  end

  test "drops results when backend configuration rotates in flight", %{
    provider: provider,
    api: api
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _api} =
        ProviderApi.update(ProviderApi.get(api.id), %{
          backend_config: %{"project_id" => "rotated-project"}
        })

      json(conn, %{"models" => %{"late-model" => %{"displayName" => "Late"}}})
    end)

    assert %{discovered: 0, errors: [error]} = ModelDiscovery.reload_api(provider, api)
    assert error =~ "discovery_configuration_changed"
    refute ProviderModel.get_by_provider_and_model(provider.id, "late-model")
  end

  test "late results cannot revive revoked provider, API, credential or model bindings", %{
    provider: provider,
    api: api
  } do
    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "existing", source: :manual})

    for mutation <- [:provider, :api, :credential, :model] do
      {:ok, _} = Provider.update(Provider.get(provider.id), %{enabled: true})
      {:ok, _} = ProviderApi.update(ProviderApi.get(api.id), %{enabled: true})

      Req.Test.stub(__MODULE__, fn conn ->
        case mutation do
          :provider ->
            Provider.update(Provider.get(provider.id), %{enabled: false})

          :api ->
            ProviderApi.update(ProviderApi.get(api.id), %{enabled: false})

          :model ->
            ProviderModel.update(ProviderModel.get(model.id), %{enabled: false})

          :credential ->
            Credentials.store_device_token("antigravity-discovery-oauth", "google_oauth", %{
              "access_token" => "rotated",
              "refresh_token" => "refresh",
              "expires_at" => System.system_time(:millisecond) + 3_600_000
            })
        end

        json(conn, %{"models" => %{"existing" => %{}, "late-model" => %{}}})
      end)

      assert %{discovered: 0, errors: [_]} = ModelDiscovery.reload_api(provider, api)
      refute ProviderModel.get_by_provider_and_model(provider.id, "late-model")
    end

    refute ProviderModel.get(model.id).enabled
  end

  test "discovery uses trusted protocol headers and never retries provider errors", %{
    provider: provider,
    api: api
  } do
    {:ok, api} =
      ProviderApi.update(api, %{
        default_headers: %{
          "x-client-name" => "spoof",
          "x-goog-user-project" => "spoof",
          "x-api-key" => "spoof"
        }
      })

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-client-name") == ["antigravity"]
      assert Plug.Conn.get_req_header(conn, "x-goog-user-project") == []
      assert Plug.Conn.get_req_header(conn, "x-api-key") == []
      Process.put(:ag_discovery_attempts, Process.get(:ag_discovery_attempts, 0) + 1)
      Plug.Conn.send_resp(conn, 429, "private upstream body")
    end)

    assert %{discovered: 0, errors: [error]} = ModelDiscovery.reload_api(provider, api)
    assert error =~ "429"
    refute error =~ "private"
    assert Process.get(:ag_discovery_attempts) == 1
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
