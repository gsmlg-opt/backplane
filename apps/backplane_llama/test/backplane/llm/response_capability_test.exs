defmodule Backplane.LLM.ResponseCapabilityTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{Provider, ProviderApi, ResponseCapability}
  alias Backplane.Settings.Credentials

  setup do
    suffix = System.unique_integer([:positive])
    name = "responses-capability-#{suffix}"
    {:ok, _credential} = Credentials.store(name, "test-key", "llm")
    {:ok, provider} = Provider.create(%{name: name, credential: name})
    :sys.get_state(Credentials.Vault)
    on_exit(fn -> :sys.get_state(Credentials.Vault) end)
    %{provider: provider}
  end

  test "native protocol alone is not lifecycle support", %{provider: provider} do
    {:ok, api} = create_api(provider, %{})
    refute api.responses_lifecycle
    refute ResponseCapability.enabled?(provider, api)
    assert {:error, :responses_lifecycle_unsupported} = ResponseCapability.validate(provider, api)
  end

  test "explicit opt-in supports native Responses with API-key credentials", %{provider: provider} do
    {:ok, api} = create_api(provider, %{responses_lifecycle: true})
    assert ResponseCapability.enabled?(provider, api)
    assert :ok = ResponseCapability.validate(provider, api)
    assert api.responses_route_ttl_seconds == 86_400
  end

  test "configuration rejects nonnative APIs and invalid retention bounds", %{provider: provider} do
    assert {:error, changeset} =
             create_api(provider, %{
               responses_lifecycle: true,
               native_protocols: [:openai_chat_completions],
               responses_route_ttl_seconds: 0
             })

    assert %{responses_lifecycle: [_], responses_route_ttl_seconds: [_]} = errors_on(changeset)
  end

  test "Codex and OAuth credentials remain unsupported despite configuration", %{
    provider: provider
  } do
    {:ok, api} = create_api(provider, %{responses_lifecycle: true})
    refute ResponseCapability.enabled?(%{provider | preset_key: "openai-codex"}, api)

    {:ok, _credential} =
      Credentials.store(provider.credential, "oauth-secret", "llm", %{
        "auth_type" => "openai_oauth"
      })

    assert {:error, :responses_lifecycle_unsupported} = ResponseCapability.validate(provider, api)
  end

  defp create_api(provider, attrs) do
    ProviderApi.create(
      Map.merge(
        %{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://mock.example/v1",
          native_protocols: [:openai_responses]
        },
        attrs
      )
    )
  end
end
