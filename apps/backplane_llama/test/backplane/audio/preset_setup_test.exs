defmodule Backplane.Audio.PresetSetupTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.Audio.{Binding, Config, PresetSetup}
  alias Backplane.LLM.{ModelAlias, Provider, ProviderApi, ProviderModel}
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _} = Credentials.store("audio-preset-key", "hidden-key", "llm")

    {:ok, _} =
      Credentials.store("audio-preset-next", "hidden-next", "service", %{"auth_type" => "api_key"})

    :ok = Config.set_enabled(false)
    :ok = Config.set_voices(%{})
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})

    on_exit(fn ->
      Config.set_voices(%{})
      Config.set_enabled(false)
    end)

    :ok
  end

  test "repeat setup keeps row IDs and changing credential and region touches only owned routes" do
    assert {:ok, first} = PresetSetup.save("audio-preset-key", "global")
    assert first.provider.name == "minimax-audio"
    assert first.provider.preset_key == "minimax-audio"
    assert length(first.bindings) == 2
    assert Repo.all(ProviderApi) == []
    assert Enum.all?(first.bindings, &(&1.api_origin == "https://api.minimax.io"))
    assert Enum.all?(first.bindings, & &1.enabled)
    refute Config.enabled?()
    assert Config.voices()["minimax-audio"] == %{"aliases" => %{}, "allow_native" => true}

    assert {:ok, again} = PresetSetup.save("audio-preset-key", "global")
    assert again.provider.id == first.provider.id
    assert Enum.map(again.bindings, & &1.id) == Enum.map(first.bindings, & &1.id)

    assert {:ok, changed} = PresetSetup.save("audio-preset-next", "china", "subscription")
    assert changed.provider.id == first.provider.id
    assert changed.provider.credential == "audio-preset-next"
    assert Enum.map(changed.bindings, & &1.id) == Enum.map(first.bindings, & &1.id)
    assert Enum.all?(changed.bindings, &(&1.api_origin == "https://api.minimaxi.com"))
    assert Enum.all?(changed.bindings, &(&1.billing_label == :subscription))
    assert ProviderModel.list_for_provider(first.provider.id) |> length() == 2
    assert Binding.list() |> length() == 2
    assert PresetSetup.current().region == "china"
  end

  test "missing, OAuth and unrelated credentials or missing region make no rows" do
    {:ok, _} = Credentials.store("audio-oauth", "hidden", "llm", %{"auth_type" => "openai_oauth"})
    {:ok, _} = Credentials.store("audio-custom", "hidden", "custom")

    for name <- ["missing", "audio-oauth", "audio-custom"] do
      assert {:error, :ineligible_credential} = PresetSetup.save(name, "global")
    end

    assert {:error, :invalid_region} = PresetSetup.save("audio-preset-key", "")
    assert Repo.get_by(Provider, name: "minimax-audio") == nil
    assert Binding.list() == []
  end

  test "name collision preserves a manually configured provider" do
    {:ok, manual} = Provider.create(%{name: "minimax-audio", credential: "audio-preset-key"})

    {:ok, model} =
      ProviderModel.create(%{provider_id: manual.id, model: "chat-model", source: :manual})

    assert {:error, :provider_conflict} = PresetSetup.save("audio-preset-next", "global")
    assert Repo.get!(Provider, manual.id).credential == "audio-preset-key"
    assert Repo.get!(ProviderModel, model.id).model == "chat-model"
    assert Binding.list() == []
  end

  test "modified route rejects setup and rolls back a credential change" do
    assert {:ok, result} = PresetSetup.save("audio-preset-key", "global")
    [binding | _] = result.bindings
    assert {:ok, _} = Binding.update(binding, %{capabilities: %{"native_formats" => ["mp3"]}})

    assert {:error, :route_conflict} =
             PresetSetup.save("audio-preset-next", "china")

    assert Repo.get!(Provider, result.provider.id).credential == "audio-preset-key"
    assert Enum.all?(Binding.list(), &(&1.api_origin == "https://api.minimax.io"))
  end

  test "modified model rejects setup and rolls back a credential change" do
    assert {:ok, result} = PresetSetup.save("audio-preset-key", "global")
    [model | _] = ProviderModel.list_for_provider(result.provider.id)
    assert {:ok, _} = ProviderModel.update(model, %{enabled: false})

    assert {:error, :route_conflict} = PresetSetup.save("audio-preset-next", "china")
    assert Repo.get!(Provider, result.provider.id).credential == "audio-preset-key"
    assert Enum.all?(Binding.list(), &(&1.api_origin == "https://api.minimax.io"))
  end

  test "existing voice policy and public aliases are not overwritten" do
    voices = %{
      "minimax-audio" => %{"aliases" => %{"hello" => "native-one"}, "allow_native" => false},
      "other" => %{"aliases" => %{}, "allow_native" => true}
    }

    :ok = Config.set_voices(voices)
    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{"existing" => "other/model"})

    assert {:ok, _} = PresetSetup.save("audio-preset-key", "global")
    assert Config.voices() == voices
    assert ModelAlias.target_for("existing") == "other/model"
    assert ModelAlias.target_for("backplane-tts") == nil
  end
end
