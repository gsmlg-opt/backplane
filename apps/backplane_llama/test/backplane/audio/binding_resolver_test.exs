defmodule Backplane.Audio.BindingResolverTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.Audio.{Binding, Config, Resolver}
  alias Backplane.LLM.{ModelAlias, Provider, ProviderModel}
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _} = Credentials.store("audio-contract-key", "test-key", "llm")
    :ok = Config.set_enabled(true)

    :ok =
      Config.set_voices(%{
        "minimax-audio" => %{"aliases" => %{"default" => "native-voice"}, "allow_native" => false}
      })

    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})
    :ok = Backplane.Settings.set(ModelAlias.provider_setting_key(), [])
    :ok = Config.set_policy(%{})

    on_exit(fn ->
      Config.set_enabled(false)
      Config.set_voices(%{})
    end)

    :ok
  end

  test "binding requires same provider/model and validates capabilities" do
    {provider, model} = create_model()
    attrs = binding_attrs(provider, model)
    assert {:ok, binding} = Binding.create(attrs)
    assert binding.operation == :speech

    assert {:error, changeset} =
             Binding.create(Map.put(attrs, :capabilities, %{"speed_min" => "fast"}))

    assert %{capabilities: [_ | _]} = errors_on(changeset)

    {:ok, other_provider} =
      Provider.create(%{name: "other-audio", credential: "audio-contract-key"})

    assert {:error, changeset} = Binding.create(Map.put(attrs, :provider_id, other_provider.id))
    assert %{provider_model_id: [_ | _]} = errors_on(changeset)
  end

  test "resolves operation-specific public names and voice policy without chat surface" do
    {provider, model} = create_model()
    {:ok, _} = Binding.create(binding_attrs(provider, model))
    {:ok, _} = ModelAlias.put("backplane-tts", "minimax-audio/speech-2.8-turbo")

    assert {:ok, resolved} = Resolver.resolve(:speech, "backplane-tts")
    assert resolved.model == "speech-2.8-turbo"
    assert resolved.credential_ref == "audio-contract-key"
    assert {:ok, "native-voice"} = Resolver.resolve_voice(resolved, "default")
    assert {:error, %{code: "unknown_voice"}} = Resolver.resolve_voice(resolved, "unknown")

    assert {:error, %{code: "operation_mismatch"}} =
             Resolver.resolve(:transcription, "backplane-tts")

    :ok = Config.set_enabled(false)
    assert {:error, %{code: "audio_disabled"}} = Resolver.resolve(:speech, "backplane-tts")
  end

  test "alias cycles and disabled bindings fail closed" do
    {provider, model} = create_model()
    {:ok, binding} = Binding.create(binding_attrs(provider, model))
    {:ok, _} = ModelAlias.put("one", "two")
    {:ok, _} = ModelAlias.put("two", "one")
    assert {:error, %{code: "alias_loop"}} = Resolver.resolve(:speech, "one")

    {:ok, _} = Binding.update(binding, %{enabled: false})

    assert {:error, %{code: "model_not_found"}} =
             Resolver.resolve(:speech, "minimax-audio/speech-2.8-turbo")
  end

  test "policy read uses safe defaults if persisted settings are malformed" do
    assert {:error, :invalid_policy} = Config.set_policy(%{"upload_bytes" => -1})
    assert {:error, :invalid_policy} = Config.set_policy(%{"input_duration_seconds" => 501})
    :ok = Backplane.Settings.set("llm.audio.policy", %{"upload_bytes" => "huge"})
    assert Config.policy()["upload_bytes"] == 25_000_000
  end

  test "capabilities enforce native values, ordered speeds and operation changes" do
    {provider, model} = create_model()
    attrs = binding_attrs(provider, model)

    for caps <- [
          %{"native_formats" => ["aac"]},
          %{"speed_min" => 1.5, "speed_max" => 1.0},
          %{"speed_min" => 0.25},
          %{"speed_min" => false},
          %{"speed_max" => false},
          %{"speed_max" => 4.0},
          %{"languages" => ["en"]},
          %{"streaming" => "true"},
          %{"output_formats" => ["unknown"]}
        ] do
      refute Binding.changeset(%Binding{}, Map.put(attrs, :capabilities, caps)).valid?
    end

    assert Binding.changeset(
             %Binding{},
             Map.put(attrs, :capabilities, %{"output_formats" => ~w(mp3 opus aac flac wav pcm)})
           ).valid?

    {:ok, binding} = Binding.create(attrs)
    refute Binding.changeset(binding, %{operation: :transcription}).valid?
    refute Binding.changeset(binding, %{credential_override: "missing"}).valid?

    for origin <- [
          "https://api.minimax.io",
          "https://api.minimax.io/v1",
          "https://api.minimax.io/v1/"
        ] do
      assert Binding.changeset(binding, %{api_origin: origin}).valid?
    end

    for origin <- [
          "https://secret@api.minimax.io",
          "https://api.minimax.io/other",
          "https://api.minimax.io?key=x",
          "http://api.minimax.io"
        ] do
      refute Binding.changeset(binding, %{api_origin: origin}).valid?
    end
  end

  test "aliases, provider updates and binding updates resolve from current authority" do
    {provider, model} = create_model()
    {:ok, binding} = Binding.create(binding_attrs(provider, model))
    {:ok, _} = ModelAlias.put("tts", model.id)
    :ok = ModelAlias.add_provider(provider.name)
    assert {:ok, resolved} = Resolver.resolve(:speech, "tts")
    assert {:error, %{status: 400}} = Resolver.resolve(:transcription, model.model)
    assert {:ok, _} = Resolver.resolve(:speech, model.model)
    assert :ok = Resolver.validate_request(resolved, %{speed: 0.5, response_format: "aac"})

    assert {:error, %{param: "speed"}} =
             Resolver.validate_request(resolved, %{speed: 0.25, response_format: "mp3"})

    {:ok, _} = Backplane.Settings.Credentials.store("audio-override", "other-key", "llm")
    {:ok, binding} = Binding.update(binding, %{credential_override: "audio-override"})
    assert {:ok, %{credential_ref: "audio-override"}} = Resolver.resolve(:speech, "tts")
    {:ok, _} = Binding.update(binding, %{enabled: false})
    assert {:error, %{status: 404}} = Resolver.resolve(:speech, "tts")
    {:ok, _} = Binding.update(binding, %{enabled: true})
    {:ok, _} = ProviderModel.update(model, %{enabled: false})
    assert {:error, %{status: 404}} = Resolver.resolve(:speech, "tts")
    {:ok, _} = ProviderModel.update(model, %{enabled: true})
    {:ok, _} = Provider.update(provider, %{enabled: false})
    assert {:error, %{status: 404}} = Resolver.resolve(:speech, "tts")
    assert {:error, %{status: 404}} = Resolver.resolve(:speech, "missing")
  end

  test "audio listings preserve generic envelope and do not enter conversation catalogs" do
    {provider, model} = create_model()
    {:ok, _} = Binding.create(binding_attrs(provider, model))
    {:ok, _} = ModelAlias.put("tts", model.id)
    :ok = ModelAlias.add_provider(provider.name)
    Backplane.LLM.ModelResolver.clear_cache()
    assert {:error, _} = Backplane.LLM.ModelResolver.resolve(:openai, "tts")
    refute model.id in Backplane.LLM.AutoModel.list_available_target_model_ids()
    assert Backplane.LLM.CodexCatalog.candidates() == []

    assert {:error, _} =
             Backplane.LLM.ModelResolver.resolve(:openai, "minimax-audio/speech-2.8-turbo")

    # Invoke the existing public list route while retaining its auth behavior.
    token = Application.get_env(:backplane, :auth_token)
    Application.put_env(:backplane, :auth_token, "audio-list-test")

    try do
      conn =
        Plug.Test.conn(:get, "/v1/models")
        |> Plug.Conn.put_req_header("authorization", "Bearer audio-list-test")
        |> Backplane.LLM.Router.call(Backplane.LLM.Router.init([]))

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)
      assert Enum.sort(Map.keys(result)) == ["data", "object"]
      assert result["object"] == "list"
      names = Enum.map(result["data"], & &1["id"])
      assert "tts" in names
      assert "speech-2.8-turbo" in names
      assert "minimax-audio/speech-2.8-turbo" in names
    after
      if is_nil(token),
        do: Application.delete_env(:backplane, :auth_token),
        else: Application.put_env(:backplane, :auth_token, token)
    end
  end

  test "policy cross limits and voice policy reject malformed configuration" do
    for policy <- [
          %{"concurrent_uploads" => 5},
          %{"media_processes" => 5},
          %{"max_provider_event_bytes" => 100_000_001},
          %{"probe_timeout_ms" => 600_001},
          %{"conversion_timeout_ms" => 600_001},
          %{"temporary_storage_bytes" => 1},
          %{"extra" => 1}
        ] do
      assert {:error, :invalid_policy} = Config.set_policy(policy)
    end

    assert {:error, :invalid_voices} =
             Config.set_voices(%{"p" => %{"aliases" => %{" " => "x"}, "allow_native" => false}})

    assert {:error, :invalid_voices} =
             Config.set_voices(%{
               "p" => %{"aliases" => %{}, "allow_native" => true, "extra" => true}
             })

    :ok = Backplane.Settings.set("llm.audio.policy", %{"upload_bytes" => "bad"})
    refute Config.policy_valid?()
    assert is_integer(Config.policy()["upload_bytes"])
    :ok = Config.set_policy(%{})
    assert Config.policy_valid?()
  end

  defp create_model do
    {:ok, provider} = Provider.create(%{name: "minimax-audio", credential: "audio-contract-key"})

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "speech-2.8-turbo",
        source: :manual
      })

    {provider, model}
  end

  defp binding_attrs(provider, model) do
    %{
      provider_id: provider.id,
      provider_model_id: model.id,
      operation: :speech,
      native_protocol: :minimax,
      api_origin: "https://api.minimax.io",
      enabled: true,
      capabilities: %{"native_formats" => ["mp3", "flac"], "speed_min" => 0.5, "speed_max" => 2.0}
    }
  end
end
