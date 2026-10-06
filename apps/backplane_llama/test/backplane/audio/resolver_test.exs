defmodule Backplane.Audio.ResolverTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.Audio.{Binding, Config, Resolver}
  alias Backplane.LLM.{ModelAlias, Provider, ProviderModel}
  alias Backplane.Settings.Credentials

  setup do
    name = "audio-catalog-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(name, "offline-key", "llm")
    {:ok, provider} = Provider.create(%{name: name, credential: name, enabled: true})

    {:ok, speech} =
      ProviderModel.create(%{provider_id: provider.id, model: "speech", enabled: true})

    {:ok, asr} = ProviderModel.create(%{provider_id: provider.id, model: "asr", enabled: true})
    :ok = Config.set_enabled(false)
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok = Backplane.Settings.set(ModelAlias.provider_setting_key(), [])

    %{provider: provider, speech: speech, asr: asr}
  end

  test "catalog follows operation and alias resolution while audio is disabled", %{
    provider: provider,
    speech: speech,
    asr: asr
  } do
    {:ok, _} = Binding.create(binding_attrs(provider, speech, :speech))
    {:ok, _} = Binding.create(binding_attrs(provider, asr, :transcription))
    :ok = ModelAlias.add_provider(provider.name)
    {:ok, _} = ModelAlias.put("speech-public", speech.id)
    {:ok, _} = ModelAlias.put("speech-chain", "speech-public")
    {:ok, _} = ModelAlias.put("asr-public", asr.id)
    {:ok, _} = ModelAlias.put("broken-audio", "missing-audio")
    {:ok, _} = ModelAlias.put("cycle-one", "cycle-two")
    {:ok, _} = ModelAlias.put("cycle-two", "cycle-one")

    refute Config.enabled?()

    assert Resolver.available_models(:speech) ==
             Enum.sort([
               "#{provider.name}/speech",
               "speech",
               "speech-chain",
               "speech-public"
             ])

    assert Resolver.available_models(:transcription) ==
             Enum.sort(["#{provider.name}/asr", "asr", "asr-public"])
  end

  test "catalog excludes disabled bindings, models, and providers", %{
    provider: provider,
    speech: speech
  } do
    {:ok, binding} = Binding.create(binding_attrs(provider, speech, :speech))
    {:ok, _} = ModelAlias.put("speech-public", speech.id)
    assert Resolver.available_models(:speech) == ["#{provider.name}/speech", "speech-public"]

    {:ok, binding} = Binding.update(binding, %{enabled: false})
    assert Resolver.available_models(:speech) == []

    {:ok, _} = Binding.update(binding, %{enabled: true})
    {:ok, speech} = ProviderModel.update(speech, %{enabled: false})
    assert Resolver.available_models(:speech) == []

    {:ok, _} = ProviderModel.update(speech, %{enabled: true})
    {:ok, provider} = Provider.update(provider, %{enabled: false})
    assert Resolver.available_models(:speech) == []

    {:ok, provider} = Provider.update(provider, %{enabled: true})
    {:ok, _} = Provider.soft_delete(provider)
    assert Resolver.available_models(:speech) == []
  end

  defp binding_attrs(provider, model, operation) do
    %{
      provider_id: provider.id,
      provider_model_id: model.id,
      operation: operation,
      native_protocol: :minimax,
      api_origin: "https://api.minimax.io",
      enabled: true,
      capabilities: %{}
    }
  end
end
