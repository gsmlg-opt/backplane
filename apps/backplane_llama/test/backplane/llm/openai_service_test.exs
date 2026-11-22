defmodule Backplane.LLM.OpenAI.ServiceTest do
  use BackplaneLlama.DataCase, async: false
  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _} = Credentials.store("openai-service-test", "upstream-key", "llm")

    {:ok, provider} =
      Provider.create(%{name: "openai-service-test", credential: "openai-service-test"})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.openai.com/v1"
      })

    %{provider: provider, api: api}
  end

  test "capabilities start enabled and are independent of chat models", %{provider: provider} do
    {:ok, service} =
      Service.create(%{provider_id: provider.id, kind: :decisions, models: ["gpt-6-luna"]})

    assert service.enabled

    assert {:ok, %{raw_model: "gpt-6-luna"}} =
             Service.resolve(:decisions, "openai-service-test/gpt-6-luna")

    assert {:ok, %{raw_model: "gpt-6-luna"}} = Service.resolve(:decisions, "gpt-6-luna")
    assert [] = Backplane.LLM.ProviderModel.list_for_provider(provider.id)
    assert {:error, :model_unavailable} = Service.resolve(:images, "gpt-6-luna")
    assert Service.list(:decisions) |> hd() |> Map.get(:id) == service.id

    {:ok, service} = Service.update(service, %{enabled: false})
    assert {:error, :model_unavailable} = Service.resolve(:decisions, "gpt-6-luna")
    {:ok, _} = Service.update(service, %{enabled: true})
    assert {:ok, _} = Service.resolve(:decisions, "gpt-6-luna")
  end

  test "defaults are explicit and ambiguous bare models fail closed", %{provider: provider} do
    attrs = %{provider_id: provider.id, kind: :images, models: ["image-a"], enabled: true}
    {:ok, service} = Service.create(attrs)
    assert {:error, :model_unavailable} = Service.resolve(:images, nil)
    assert {:error, invalid} = Service.update(service, %{default_model: "other"})
    assert errors_on(invalid).default_model
    {:ok, _} = Service.update(service, %{default_model: "image-a"})
    assert {:ok, %{raw_model: "image-a"}} = Service.resolve(:images, nil)
    {:ok, second} = Provider.create(%{name: "other-openai", credential: "openai-service-test"})

    {:ok, _} =
      ProviderApi.create(%{
        provider_id: second.id,
        api_surface: :openai,
        base_url: "https://api.openai.com/v1"
      })

    {:ok, _} = Service.create(%{attrs | provider_id: second.id})
    assert {:error, :ambiguous_model} = Service.resolve(:images, "image-a")
    assert {:ok, %{provider: %{id: id}}} = Service.resolve(:images, "openai-service-test/image-a")
    assert id == provider.id
  end

  test "Realtime budgets default independently of HTTP bodies and require finite positive integers",
       %{
         provider: provider
       } do
    assert {:ok, service} = Service.create(%{provider_id: provider.id, kind: :realtime})
    assert service.realtime_max_input_bytes == 536_870_912
    assert service.realtime_max_output_bytes == 536_870_912
    assert service.max_request_bytes == 50_000_000
    assert service.max_response_bytes == 100_000_000

    for field <- [:realtime_max_input_bytes, :realtime_max_output_bytes],
        value <- [nil, 0, -1, 2_147_483_648, "infinity", 1.5] do
      assert {:error, invalid} = Service.update(service, %{field => value})
      assert Map.has_key?(errors_on(invalid), field)
    end

    assert {:ok, service} =
             Service.update(service, %{
               realtime_max_input_bytes: 1,
               realtime_max_output_bytes: 2_147_483_647
             })

    assert service.max_request_bytes == 50_000_000
    assert service.max_response_bytes == 100_000_000

    assert {:ok, updated} =
             Service.update(service, %{max_request_bytes: 10, max_response_bytes: 20})

    assert updated.realtime_max_input_bytes == 1
    assert updated.realtime_max_output_bytes == 2_147_483_647
  end

  test "other capabilities do not require Realtime budgets", %{provider: provider} do
    assert {:ok, service} =
             Service.create(%{
               provider_id: provider.id,
               kind: :speech,
               realtime_max_input_bytes: nil,
               realtime_max_output_bytes: nil
             })

    assert service.max_request_bytes == 50_000_000
    assert service.max_response_bytes == 100_000_000
  end

  test "OAuth credentials cannot enable native Platform APIs", %{provider: provider} do
    {:ok, _} =
      Credentials.store("openai-service-test", "oauth-key", "llm", %{
        "auth_type" => "openai_codex_oauth"
      })

    assert {:error, changeset} =
             Service.create(%{provider_id: provider.id, kind: :realtime, models: ["voice"]})

    assert errors_on(changeset).provider_id
  end

  test "passthrough models need no catalog and respect explicit provider selection", %{
    provider: provider
  } do
    {:ok, service} = Service.create(%{provider_id: provider.id, kind: :embeddings})
    assert service.model_policy == :passthrough
    assert {:ok, %{raw_model: "new-embedding"}} = Service.resolve(:embeddings, "new-embedding")
    assert {:error, :model_unavailable} = Service.resolve(:embeddings, nil)

    {:ok, other} = Provider.create(%{name: "other-openai", credential: provider.credential})

    {:ok, _} =
      ProviderApi.create(%{
        provider_id: other.id,
        api_surface: :openai,
        base_url: "https://api.openai.com/v1"
      })

    {:ok, _} = Service.create(%{provider_id: other.id, kind: :embeddings})
    assert {:error, :ambiguous_model} = Service.resolve(:embeddings, "new-embedding")

    assert {:ok, %{provider: %{id: selected_id}, raw_model: "new-embedding"}} =
             Service.resolve(:embeddings, "openai-service-test/new-embedding")

    assert selected_id == provider.id
    {:ok, _} = Provider.update(provider, %{enabled: false})

    assert {:error, :model_unavailable} =
             Service.resolve(:embeddings, "openai-service-test/new-embedding")
  end

  test "explicit passthrough policy accepts models outside an optional list", %{
    provider: provider
  } do
    {:ok, service} =
      Service.create(%{
        provider_id: provider.id,
        kind: :speech,
        model_policy: :passthrough,
        models: ["suggested-voice"],
        default_model: "default-voice"
      })

    assert service.model_policy == :passthrough
    assert {:ok, %{raw_model: "another-voice"}} = Service.resolve(:speech, "another-voice")
    assert {:ok, %{raw_model: "default-voice"}} = Service.resolve(:speech, nil)
  end

  test "independent API toggles preserve model restrictions and limits", %{provider: provider} do
    {:ok, service} =
      Service.create(%{
        provider_id: provider.id,
        kind: :speech,
        models: ["restricted-voice"],
        default_model: "restricted-voice",
        request_timeout_ms: 45000
      })

    assert service.model_policy == :allowlist
    {:ok, disabled} = Service.update(service, %{enabled: false})
    {:ok, enabled} = Service.update(disabled, %{enabled: true})
    assert enabled.models == ["restricted-voice"]
    assert enabled.default_model == "restricted-voice"
    assert enabled.request_timeout_ms == 45000
    assert {:error, :model_unavailable} = Service.resolve(:speech, "other-voice")

    {:ok, _} =
      Credentials.store("openai-service-test", "oauth-key", "llm", %{
        "auth_type" => "openai_codex_oauth"
      })

    assert {:ok, %{enabled: false}} = Service.update(enabled, %{enabled: false})
    assert {:error, changeset} = Service.create(%{provider_id: provider.id, kind: :realtime})
    assert errors_on(changeset).provider_id
  end

  test "credential and provider/API defaults replace client-owned credentials safely", %{
    provider: provider,
    api: api
  } do
    {:ok, provider} =
      Provider.update(provider, %{
        default_headers: %{"authorization" => "unsafe", "x-provider" => "yes"}
      })

    {:ok, api} =
      ProviderApi.update(api, %{
        default_headers: %{"cookie" => "unsafe", "OpenAI-Project" => "configured-project"}
      })

    assert {:ok, headers} = Service.auth_headers(%{provider: provider, api: api})

    assert Enum.filter(headers, &(elem(&1, 0) == "authorization")) == [
             {"authorization", "Bearer upstream-key"}
           ]

    assert {"x-provider", "yes"} in headers
    assert {"openai-project", "configured-project"} in headers
    refute List.keymember?(headers, "cookie", 0)
    assert Service.url(%{api: api}, "images/edits") == "https://api.openai.com/v1/images/edits"

    assert Service.url(%{api: %{api | base_url: "https://api.openai.com"}}, "decisions") ==
             "https://api.openai.com/v1/decisions"
  end
end
