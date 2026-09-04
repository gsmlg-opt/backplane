defmodule Backplane.LLM.ModelDiscoveryProxyTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.ModelDiscovery
  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings.{Credentials, TokenCache}

  setup do
    previous_req_options = Application.get_env(:backplane, :llm_model_discovery_req_options)

    Application.put_env(:backplane, :llm_model_discovery_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous_req_options do
        Application.put_env(:backplane, :llm_model_discovery_req_options, previous_req_options)
      else
        Application.delete_env(:backplane, :llm_model_discovery_req_options)
      end
    end)

    TokenCache.clear()
    expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

    {:ok, _} =
      Credentials.store_device_token(
        "codex-discovery-token",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "id_token" => "codex-id-token",
          "access_token" => "chatgpt-access-token",
          "refresh_token" => "refresh-token",
          "expires_at" => expires_at
        },
        %{"account_id" => "acc-123"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "codex-discovery",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "https://chatgpt.com/backend-api/codex",
        credential: "codex-discovery-token",
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex",
        model_discovery_enabled: true,
        model_discovery_path: "/models"
      })

    old_model =
      ProviderModel.create(%{provider_id: provider.id, model: "gpt-5.5", source: :discovered})

    old_surface =
      with {:ok, old_model} <- old_model do
        ProviderModelSurface.create(%{provider_model_id: old_model.id, provider_api_id: api.id})
      end

    {:ok, %{provider: provider, api: api, old_model: old_model, old_surface: old_surface}}
  end

  test "prefers Codex slugs and refreshes upstream metadata", %{provider: provider, api: api} do
    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "gpt-5.6-sol",
        source: :discovered,
        metadata: %{"capabilities" => %{"reasoning" => false}, "local_note" => "keep"}
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        metadata: %{"capabilities" => %{"reasoning" => false}, "surface_note" => "keep"}
      })

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/backend-api/codex/models"
      assert ["Bearer chatgpt-access-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert ["acc-123"] = Plug.Conn.get_req_header(conn, "chatgpt-account-id")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "models" => [
            %{
              "id" => "wrong-id",
              "slug" => "gpt-5.6-sol",
              "capabilities" => %{"reasoning" => true}
            }
          ]
        })
      )
    end)

    assert %{discovered: 1, created: 0, updated: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    model = ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.6-sol")

    assert model.metadata == %{
             "id" => "wrong-id",
             "slug" => "gpt-5.6-sol",
             "api_surface" => "openai",
             "capabilities" => %{"reasoning" => true},
             "local_note" => "keep"
           }

    assert [surface] = model.surfaces

    assert surface.metadata == %{
             "id" => "wrong-id",
             "slug" => "gpt-5.6-sol",
             "api_surface" => "openai",
             "capabilities" => %{"reasoning" => true},
             "local_note" => "keep",
             "surface_note" => "keep"
           }

    refute ProviderModel.get_by_provider_and_model(provider.id, "wrong-id")
  end

  test "keeps manual models and disables stale discovered models instead of deleting them", %{
    provider: provider
  } do
    {:ok, _manual} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "local-manual-model",
        source: :manual
      })

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert %{source: :manual, enabled: true} =
             ProviderModel.get_by_provider_and_model(provider.id, "local-manual-model")

    assert %{source: :discovered, enabled: false, surfaces: []} =
             ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert %{source: :discovered, enabled: true, surfaces: [%{enabled: true}]} =
             ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
  end

  test "does not revive a model or surface disabled by an operator", %{
    provider: provider,
    api: api
  } do
    model = ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
    [surface] = model.surfaces

    {:ok, _model} =
      ProviderModel.update(model, %{enabled: false, display_name: "Operator label"})

    {:ok, _surface} = ProviderModelSurface.update(surface, %{enabled: false})

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "models" => [%{"slug" => "gpt-5.5", "capabilities" => %{"reasoning" => true}}]
        })
      )
    end)

    assert %{discovered: 1, updated: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    model = ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
    assert model.enabled == false
    assert model.display_name == "Operator label"
    assert model.metadata["capabilities"] == %{"reasoning" => true}

    surface = ProviderModelSurface.get_by_model_and_api(model.id, api.id)
    assert surface.enabled == false
    assert surface.last_seen_at
  end

  test "revives migration-stale models after real discovery and clears the marker", %{
    provider: provider
  } do
    model = ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")

    {:ok, _model} =
      ProviderModel.update(model, %{
        enabled: false,
        metadata: %{"backplane_discovery_stale" => true, "local_note" => "keep"}
      })

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.5"}]}))
    end)

    assert %{discovered: 1, updated: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    model = ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
    assert model.enabled == true
    assert model.metadata["local_note"] == "keep"
    refute Map.has_key?(model.metadata, "backplane_discovery_stale")
  end

  test "records last discovery only after every model persists successfully", %{
    provider: provider
  } do
    {:ok, foreign_provider} =
      Provider.create(%{
        name: "foreign-codex-discovery",
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "https://chatgpt.com/backend-api/codex",
        credential: "codex-discovery-token",
        models: []
      })

    {:ok, foreign_api} =
      ProviderApi.create(%{
        provider_id: foreign_provider.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex",
        model_discovery_enabled: true,
        model_discovery_path: "/models"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{errors: [_error]} = ModelDiscovery.reload_api(provider, foreign_api)
    refute ProviderApi.get(foreign_api.id).last_discovered_at
    refute ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.6-sol")
  end

  test "keeps last-known-good models on discovery failure", %{provider: provider} do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.resp(conn, 401, "unauthorized") end)

    assert %{errors: ["openai: HTTP 401"]} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
  end

  test "sends configured client version to Codex discovery", %{provider: provider} do
    Application.put_env(:backplane, :openai_codex_client_version, "0.51.0")

    on_exit(fn ->
      Application.delete_env(:backplane, :openai_codex_client_version)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == "client_version=0.51.0"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))
  end

  test "sends client version through a custom Codex gateway and preserves existing query", %{
    provider: provider,
    api: api
  } do
    {:ok, _api} =
      ProviderApi.update(api, %{
        base_url: "https://codex-gateway.internal/backend-api/codex",
        model_discovery_path: "/models?region=west"
      })

    Req.Test.stub(__MODULE__, fn conn ->
      assert URI.decode_query(conn.query_string) == %{
               "client_version" => "0.0.0",
               "region" => "west"
             }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))
  end

  test "uses the Codex compatibility client version when none is configured", %{
    provider: provider
  } do
    previous_env = System.get_env("OPENAI_CODEX_CLIENT_VERSION")
    System.delete_env("OPENAI_CODEX_CLIENT_VERSION")

    on_exit(fn -> restore_system_env("OPENAI_CODEX_CLIENT_VERSION", previous_env) end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == "client_version=0.0.0"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))
  end

  test "does not prune last-known-good catalog when Codex returns empty models", %{
    provider: provider
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => []}))
    end)

    assert %{errors: ["openai: :empty_model_list"]} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
  end

  test "does not prune last-known-good catalog when OpenAI data list is empty", %{
    provider: provider
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)

    assert %{errors: ["openai: :empty_model_list"]} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")
  end

  test "does not prune last-known-good catalog when a Codex entry has an id but no slug", %{
    provider: provider,
    api: api
  } do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"models" => [%{"id" => "wrong-id", "display_name" => "GPT"}]})
      )
    end)

    assert %{errors: ["openai: :empty_model_list"]} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert %{enabled: true, surfaces: [%{provider_api_id: api_id}]} =
             ProviderModel.get_by_provider_and_model(provider.id, "gpt-5.5")

    assert api_id == api.id
    refute ProviderModel.get_by_provider_and_model(provider.id, "wrong-id")
    refute ProviderApi.get(api.id).last_discovered_at
  end

  test "credential headers uniquely replace conflicting discovery defaults", %{
    provider: provider,
    api: api
  } do
    {:ok, provider} =
      Provider.update(provider, %{
        default_headers: %{
          "AUTHORIZATION" => "Bearer stale-provider",
          "ChatGPT-Account-ID" => "stale-provider-account",
          "Originator" => "provider-originator"
        }
      })

    {:ok, _api} =
      ProviderApi.update(api, %{
        default_headers: %{
          "authorization" => "Bearer stale-api",
          "chatgpt-account-id" => "stale-api-account",
          "originator" => "api-originator"
        }
      })

    Req.Test.stub(__MODULE__, fn conn ->
      assert ["Bearer chatgpt-access-token"] =
               Plug.Conn.get_req_header(conn, "authorization")

      assert ["acc-123"] = Plug.Conn.get_req_header(conn, "chatgpt-account-id")
      assert ["provider-originator"] = Plug.Conn.get_req_header(conn, "originator")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))
  end

  test "emits discovery telemetry", %{provider: provider} do
    parent = self()

    :telemetry.attach(
      "codex-discovery-test",
      [:backplane, :codex, :models, :discovery, :completed],
      fn _event, measurements, metadata, _config ->
        send(parent, {:completed, measurements, metadata})
      end,
      nil
    )

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}))
    end)

    assert %{discovered: 1, errors: []} =
             ModelDiscovery.reload_provider(Provider.get(provider.id))

    assert_receive {:completed, %{count: 1}, metadata}, 1_000
    assert metadata.source == :remote
    assert metadata.provider_id == provider.id
    assert metadata.provider_name == provider.name
    assert metadata.endpoint == "models"
  after
    :telemetry.detach("codex-discovery-test")
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
