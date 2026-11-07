defmodule Backplane.LLM.HostServicesTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.Embedding

  alias Backplane.LLM.{
    CredentialPlug,
    HostService,
    HostServices,
    ModelDiscovery,
    Provider,
    ProviderApi
  }

  alias Backplane.Settings.Credentials

  setup do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.insert_all("skill_hosts", [
      %{
        id: Ecto.UUID.dump!(id),
        name: "host-services-#{id}",
        memory_scope: "host-services-#{id}",
        inserted_at: now,
        updated_at: now
      }
    ])

    %{host_id: id}
  end

  test "stores exact explicit endpoints, versions snapshots and removes disabled services", c do
    Phoenix.PubSub.subscribe(Backplane.PubSub, "host_api_services:#{c.host_id}")
    endpoints = %{"openai_responses" => "http://127.0.0.1:8000/custom/responses"}

    assert {:ok, service} =
             HostServices.create(%{host_id: c.host_id, name: "local", endpoints: endpoints})

    assert_receive :host_api_services_changed

    assert [%{"id" => id, "endpoints" => ^endpoints, "revision" => 1}] =
             HostServices.snapshot(c.host_id)

    assert id == service.id

    assert {:ok, ^service, "http://127.0.0.1:8000/custom/responses"} =
             HostServices.endpoint(id, :openai_responses)

    assert {:error, :unsupported_api} = HostServices.endpoint(id, :anthropic_messages)
    assert {:ok, disabled} = HostServices.update(service, %{enabled: false})
    assert disabled.revision == 2
    assert [] = HostServices.snapshot(c.host_id)
    assert {:error, :host_service_unavailable} = HostServices.endpoint(id, :openai_responses)
  end

  test "rejects unknown protocols, missing endpoints and credential-bearing URLs", c do
    assert {:error, missing_endpoints} =
             HostServices.create(%{host_id: c.host_id, name: "no-endpoints"})

    assert ["must declare at least one supported API endpoint"] =
             errors_on(missing_endpoints).endpoints

    for endpoints <- [
          %{},
          %{"vllm" => "http://localhost:8000"},
          %{"openai_responses" => "file:///tmp/api"},
          %{"openai_responses" => "http://secret@localhost:8000/v1/responses"}
        ] do
      assert {:error, changeset} =
               HostServices.create(%{host_id: c.host_id, name: "bad", endpoints: endpoints})

      assert errors_on(changeset)[:endpoints]
    end

    assert {:error, changeset} =
             HostServices.create(%{
               host_id: Ecto.UUID.generate(),
               name: "missing-host",
               endpoints: %{"openai_responses" => "http://localhost:8000/v1/responses"}
             })

    assert errors_on(changeset)[:host_id]
  end

  test "rejects a service beyond the bounded per-host inventory", c do
    now = DateTime.utc_now()

    rows =
      Enum.map(1..64, fn index ->
        %{
          host_id: c.host_id,
          name: "bounded-#{index}",
          enabled: true,
          endpoints: %{"openai_responses" => "http://localhost:8000/v1/responses"},
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      end)

    assert {64, _} = Repo.insert_all(HostService, rows)

    assert {:error, changeset} =
             HostServices.create(%{
               host_id: c.host_id,
               name: "overflow",
               endpoints: %{
                 "openai_responses" => "http://localhost:8000/v1/responses"
               }
             })

    assert ["supports at most 64 API services"] = errors_on(changeset).host_id
    assert length(HostServices.snapshot(c.host_id)) == 64
  end

  test "only host-linked providers can omit credentials and APIs must be declared", c do
    assert {:error, direct_changeset} = Provider.create(%{name: "direct-no-key"})
    assert errors_on(direct_changeset)[:credential]

    assert {:ok, service} =
             HostServices.create(%{
               host_id: c.host_id,
               name: "inference",
               endpoints: %{"openai_responses" => "http://localhost:8000/native/responses"}
             })

    assert {:ok, provider} =
             Provider.create(%{
               name: "hosted-provider",
               host_service_id: service.id,
               default_headers: %{"x-host-setting" => "set"}
             })

    assert {:ok, headers} = CredentialPlug.build_auth_headers(provider, :openai)
    assert {"x-host-setting", "set"} in headers
    refute Enum.any?(headers, fn {key, _} -> key == "authorization" end)

    assert {:ok, api} =
             ProviderApi.create(%{
               provider_id: provider.id,
               api_surface: :openai,
               native_protocols: [:openai_responses],
               model_discovery_enabled: true,
               model_discovery_path: "/models"
             })

    assert api.base_url == "http://localhost:8000/native/responses"
    refute api.model_discovery_enabled
    assert is_nil(api.model_discovery_path)

    assert %{errors: ["host services use explicitly configured models"]} =
             ModelDiscovery.reload_api(provider, api)

    assert {:error, unsupported} =
             ProviderApi.update(api, %{native_protocols: [:openai_chat_completions]})

    assert errors_on(unsupported)[:native_protocols]
    assert {:error, lifecycle} = ProviderApi.update(api, %{responses_lifecycle: true})
    assert errors_on(lifecycle)[:responses_lifecycle]
    assert {:error, detach} = Provider.update(provider, %{host_service_id: nil})
    assert errors_on(detach)[:credential]
    assert {:error, in_use} = HostServices.delete(service)
    assert errors_on(in_use)[:id]
  end

  test "embedding services retain normal model routing and allow a local endpoint without a key",
       c do
    assert {:ok, service} =
             HostServices.create(%{
               host_id: c.host_id,
               name: "vectors",
               endpoints: %{"openai_embeddings" => "http://localhost:9000/encode"}
             })

    assert {:ok, %{provider: provider, model: model}} =
             Embedding.create_provider_with_model(%{
               "name" => "host-vectors",
               "host_service_id" => service.id,
               "enabled" => "true",
               "model" => "qwen-embedding",
               "model_enabled" => "true"
             })

    assert provider.base_url == "http://localhost:9000/encode"
    assert {:ok, []} = Embedding.build_auth_headers(provider)

    assert {:ok, resolved, "qwen-embedding"} =
             Embedding.resolve_model(Embedding.model_id(%{model | provider: provider}))

    assert resolved.host_service_id == service.id
  end

  test "moving an existing provider to a host requires disabling unsupported transports", c do
    credential = "host-lifecycle-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(credential, "test-host-lifecycle-key", "llm")
    {:ok, provider} = Provider.create(%{name: "lifecycle-switch", credential: credential})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:1/v1",
        native_protocols: [:openai_responses],
        responses_lifecycle: true
      })

    {:ok, service} =
      HostServices.create(%{
        host_id: c.host_id,
        name: "responses",
        endpoints: %{
          "openai_responses" => "http://127.0.0.1:1/v1/responses"
        }
      })

    assert {:error, changeset} = Provider.update(provider, %{host_service_id: service.id})
    assert errors_on(changeset)[:host_service_id]
    {:ok, _} = ProviderApi.update(api, %{responses_lifecycle: false})
    assert {:ok, _} = Provider.update(provider, %{host_service_id: service.id})
  end

  test "discovery reload rechecks a stale direct provider after it switches to a host", c do
    credential = "host-discovery-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Credentials.store(credential, "test-host-discovery-key", "llm")
    assert {:ok, provider} = Provider.create(%{name: "stale-discovery", credential: credential})

    assert {:ok, api} =
             ProviderApi.create(%{
               provider_id: provider.id,
               api_surface: :openai,
               base_url: "http://127.0.0.1:1/v1",
               native_protocols: [:openai_chat_completions],
               model_discovery_enabled: true,
               model_discovery_path: "/models"
             })

    assert {:ok, service} =
             HostServices.create(%{
               host_id: c.host_id,
               name: "local-chat",
               endpoints: %{
                 "openai_chat_completions" => "http://127.0.0.1:1/v1/chat/completions"
               }
             })

    assert {:ok, _} = Provider.update(provider, %{host_service_id: service.id})

    assert %{errors: [error]} = ModelDiscovery.reload_api(provider, api)
    assert error =~ "discovery_disabled"
  end
end
