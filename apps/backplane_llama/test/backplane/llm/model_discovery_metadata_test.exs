defmodule Backplane.LLM.ModelDiscoveryMetadataTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{ModelDiscovery, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings.Credentials

  setup do
    HTTP.Test.verify_on_exit!()
    previous = Application.get_env(:backplane, :llm_model_discovery_http_options)

    Application.put_env(:backplane, :llm_model_discovery_http_options,
      adapter: {HTTP.Test, __MODULE__},
      receive_timeout: 1234
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :llm_model_discovery_http_options, previous)
      else
        Application.delete_env(:backplane, :llm_model_discovery_http_options)
      end
    end)

    {:ok, _} = Credentials.store("metadata-discovery-key", "test-discovery-key", "llm")
    :ok
  end

  test "Ollama show enriches each model without changing raw list fields" do
    {provider, api} = provider_api("ollama", "http://localhost:11434/deployment/v1/")
    owner = self()

    supplemental = %{
      "parameters" => "num_ctx 8192\ntemperature 0.7",
      "model_info" => %{"llama.context_length" => 131_072},
      "capabilities" => ["completion", "vision", "tools"],
      "details" => %{"parameter_size" => "8B", "quantization_level" => "Q4_K_M"}
    }

    HTTP.Test.stub(__MODULE__, fn request ->
      assert request.url.host == "localhost"
      assert request.url.port == 11434
      assert_headers(request)
      send(owner, {request.method, request.url.path})

      case {request.method, request.url.path} do
        {:get, "/deployment/v1/models"} ->
          json(%{"data" => [raw_model("llama:latest"), raw_model("llama:small")]})

        {:post, "/deployment/api/show"} ->
          assert %{"model" => model} = Jason.decode!(IO.iodata_to_binary(request.body))
          assert model in ["llama:latest", "llama:small"]
          json(supplemental)
      end
    end)

    assert %{discovered: 2, created: 2, errors: []} = ModelDiscovery.reload_api(provider, api)
    assert_received {:get, "/deployment/v1/models"}
    assert_received {:post, "/deployment/api/show"}
    assert_received {:post, "/deployment/api/show"}
    refute_received {_, _}

    for model_id <- ["llama:latest", "llama:small"] do
      model = ProviderModel.get_by_provider_and_model(provider.id, model_id)
      assert Map.take(model.metadata, Map.keys(raw_model(model_id))) == raw_model(model_id)
      assert model.metadata["ollama"] == supplemental
      assert [surface] = model.surfaces
      assert surface.metadata["ollama"] == supplemental
    end
  end

  test "SGLang enriches a sole served alias using a native root endpoint" do
    {provider, api} = provider_api("sglang", "https://inference.example.test/v1")
    owner = self()

    supplemental = %{
      "model_path" => "Qwen/Qwen2.5-7B-Instruct",
      "served_model_name" => "served-alias",
      "is_generation" => true,
      "has_image_understanding" => false,
      "has_audio_understanding" => false,
      "architectures" => ["Qwen2ForCausalLM"]
    }

    HTTP.Test.stub(__MODULE__, fn request ->
      assert request.url.host == "inference.example.test"
      assert_headers(request)
      send(owner, {request.method, request.url.path})

      case {request.method, request.url.path} do
        {:get, "/v1/models"} -> json(%{"data" => [raw_model("served-alias")]})
        {:get, "/model_info"} -> json(supplemental)
      end
    end)

    assert %{discovered: 1, created: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
    assert_received {:get, "/v1/models"}
    assert_received {:get, "/model_info"}
    refute_received {_, _}
    model = ProviderModel.get_by_provider_and_model(provider.id, "served-alias")
    assert model.metadata["sglang"] == supplemental
    assert model.metadata["max_model_len"] == 4096
    refute Map.has_key?(model.metadata["sglang"], "context_length")
  end

  test "SGLang does not attribute base model metadata to unrelated models" do
    {provider, api} = provider_api("sglang", "http://localhost:30000")
    owner = self()
    supplemental = %{"model_path" => "base-model", "is_generation" => true}

    HTTP.Test.stub(__MODULE__, fn request ->
      send(owner, request.url.path)

      case request.url.path do
        "/models" -> json(%{"data" => [raw_model("base-model"), raw_model("adapter")]})
        "/model_info" -> json(supplemental)
      end
    end)

    assert %{discovered: 2, errors: []} = ModelDiscovery.reload_api(provider, api)
    assert_received "/model_info"
    refute_received "/model_info"

    assert ProviderModel.get_by_provider_and_model(provider.id, "base-model").metadata["sglang"] ==
             supplemental

    refute Map.has_key?(
             ProviderModel.get_by_provider_and_model(provider.id, "adapter").metadata,
             "sglang"
           )
  end

  for status <- [404, 405] do
    test "SGLang falls back to deprecated endpoint only after HTTP #{status}" do
      {provider, api} = provider_api("sglang", "http://localhost:30000/deployment/v1")
      owner = self()
      supplemental = %{"model_path" => "source-model", "served_model_name" => "listed-model"}

      HTTP.Test.stub(__MODULE__, fn request ->
        assert request.method == :get
        assert_headers(request)
        send(owner, request.url.path)

        case request.url.path do
          "/deployment/v1/models" -> json(%{"data" => [raw_model("listed-model")]})
          "/deployment/model_info" -> HTTP.Test.response(unquote(status), "unsupported")
          "/deployment/get_model_info" -> json(supplemental)
        end
      end)

      assert %{discovered: 1, created: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
      assert_received "/deployment/v1/models"
      assert_received "/deployment/model_info"
      assert_received "/deployment/get_model_info"
      refute_received _
      model = ProviderModel.get_by_provider_and_model(provider.id, "listed-model")
      assert model.metadata["sglang"] == supplemental
      assert model.metadata["max_model_len"] == 4096
    end
  end

  for served_name <- ["other-model", "", nil] do
    test "SGLang present served name #{inspect(served_name)} prevents sole model fallback" do
      {provider, api} = provider_api("sglang", "http://localhost:30000/v1")

      HTTP.Test.stub(__MODULE__, fn request ->
        case request.url.path do
          "/v1/models" ->
            json(%{"data" => [raw_model("listed-model")]})

          "/model_info" ->
            json(%{
              "model_path" => "listed-model",
              "served_model_name" => unquote(served_name)
            })
        end
      end)

      assert %{discovered: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
      model = ProviderModel.get_by_provider_and_model(provider.id, "listed-model")
      refute Map.has_key?(model.metadata, "sglang")
      assert [surface] = model.surfaces
      refute Map.has_key?(surface.metadata, "sglang")
    end
  end

  test "SGLang served name takes priority over model path in a multiple-model list" do
    {provider, api} = provider_api("sglang", "http://localhost:30000/v1")
    supplemental = %{"model_path" => "source-model", "served_model_name" => "served-model"}

    HTTP.Test.stub(__MODULE__, fn request ->
      case request.url.path do
        "/v1/models" ->
          json(%{"data" => [raw_model("source-model"), raw_model("served-model")]})

        "/model_info" ->
          json(supplemental)
      end
    end)

    assert %{discovered: 2, errors: []} = ModelDiscovery.reload_api(provider, api)
    source = ProviderModel.get_by_provider_and_model(provider.id, "source-model")
    served = ProviderModel.get_by_provider_and_model(provider.id, "served-model")
    refute Map.has_key?(source.metadata, "sglang")
    assert served.metadata["sglang"] == supplemental
  end

  test "SGLang retains sole alias compatibility when served name is absent" do
    {provider, api} = provider_api("sglang", "http://localhost:30000/v1")
    supplemental = %{"model_path" => "source-model", "is_generation" => true}

    HTTP.Test.stub(__MODULE__, fn request ->
      case request.url.path do
        "/v1/models" -> json(%{"data" => [raw_model("served-alias")]})
        "/model_info" -> json(supplemental)
      end
    end)

    assert %{discovered: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
    model = ProviderModel.get_by_provider_and_model(provider.id, "served-alias")
    assert model.metadata["sglang"] == supplemental
  end

  for preset <- ["ollama", "sglang"] do
    test "#{preset} does not request supplemental metadata for empty details" do
      {provider, api} = provider_api(unquote(preset), "http://localhost:30000/v1")
      owner = self()

      HTTP.Test.stub(__MODULE__, fn request ->
        send(owner, request.url.path)
        assert request.url.path == "/v1/models"
        json([])
      end)

      assert %{discovered: 0, errors: []} = ModelDiscovery.reload_api(provider, api)
      assert_received "/v1/models"
      refute_received _
    end
  end

  for preset <- ["custom", "vllm", "ollama-cloud"] do
    test "#{preset} discovery makes no supplemental requests" do
      {provider, api} = provider_api(unquote(preset), "https://models.example.test/v1")
      owner = self()

      HTTP.Test.stub(__MODULE__, fn request ->
        assert request.url.path == "/v1/models"
        send(owner, :models_requested)
        json(%{"data" => [raw_model("listed-model")]})
      end)

      assert %{discovered: 1, created: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
      assert_received :models_requested
      refute_received :models_requested
      model = ProviderModel.get_by_provider_and_model(provider.id, "listed-model")
      assert model.metadata["max_model_len"] == 4096
      refute Map.has_key?(model.metadata, "ollama")
      refute Map.has_key?(model.metadata, "sglang")
    end
  end

  for preset <- ["ollama", "sglang"] do
    test "#{preset} supplemental requests retain configured timeout and connection options" do
      preset = unquote(preset)
      {provider, api} = provider_api(preset, "https://models.example.test:8443/deployment/v1")
      proxy = {:http, "proxy.example.test", 3128, []}
      owner = self()

      Application.put_env(:backplane, :llm_model_discovery_http_options,
        adapter: {HTTP.Test, __MODULE__},
        receive_timeout: 1234,
        connect_options: [proxy: proxy]
      )

      # A transient supplemental failure proves retries are disabled: a retrying
      # client would send it again, and the catalog must still persist.
      HTTP.Test.stub(__MODULE__, fn request ->
        send(owner, {:discovery_request, request})

        if String.ends_with?(request.url.path, "/models"),
          do: json(%{"data" => [%{"id" => "listed-model"}]}),
          else: HTTP.Test.response(503, "unavailable")
      end)

      assert %{discovered: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
      assert_received {:discovery_request, list_request}
      assert_received {:discovery_request, supplemental_request}
      refute_received {:discovery_request, _}
      assert list_request.url.path == "/deployment/v1/models"

      for request <- [list_request, supplemental_request] do
        assert request.transport_options[:timeout] == 1234
        assert request.transport_options[:proxy] == proxy
        assert request.url.host == "models.example.test"
        assert request.url.port == 8443

        assert HTTP.Headers.get_all(request.headers, "authorization") == [
                 "Bearer test-discovery-key"
               ]
      end

      assert list_request.transport_options[:redirect] == :follow
      assert supplemental_request.transport_options[:redirect] == :manual

      if preset == "ollama" do
        assert supplemental_request.url.path == "/deployment/api/show"
        assert supplemental_request.method == :post

        assert Jason.decode!(IO.iodata_to_binary(supplemental_request.body)) == %{
                 "model" => "listed-model"
               }
      else
        assert supplemental_request.url.path == "/deployment/model_info"
        assert supplemental_request.method == :get
      end
    end
  end

  for preset <- ["ollama", "sglang"],
      failure <- [
        :unsupported,
        :method_not_allowed,
        :unauthorized,
        :forbidden,
        :server_error,
        :transport,
        :invalid,
        :empty,
        :non_map,
        :malformed_json,
        :redirect
      ] do
    test "#{preset} supplemental #{failure} retains catalog and known-good metadata" do
      preset = unquote(preset)
      {provider, api} = provider_api(preset, "http://localhost:11434/v1")
      known = %{"capabilities" => ["completion"], "model_path" => "listed-model"}
      owner = self()

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "listed-model",
          source: :discovered,
          metadata: %{preset => known, "local_note" => "keep"}
        })

      {:ok, _} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          metadata: %{preset => known, "surface_note" => "keep"}
        })

      HTTP.Test.stub(__MODULE__, fn request ->
        send(owner, request.url.path)

        if request.url.path == "/v1/models" do
          json(%{"data" => [raw_model("listed-model"), raw_model("new-model")]})
        else
          case unquote(failure) do
            :unsupported ->
              HTTP.Test.response(404, "unsupported")

            :method_not_allowed ->
              HTTP.Test.response(405, "unsupported")

            :unauthorized ->
              HTTP.Test.response(401, "private error")

            :forbidden ->
              HTTP.Test.response(403, "private error")

            :server_error ->
              HTTP.Test.response(500, "private error")

            :transport ->
              HTTP.Test.transport_error(:timeout)

            :invalid ->
              json(%{"error" => "private error"})

            :empty ->
              json(%{})

            :non_map ->
              json([])

            :malformed_json ->
              HTTP.Test.response(200, "{", [{"content-type", "application/json"}])

            :redirect ->
              HTTP.Test.response(302, "", [
                {"location", "https://untrusted.example.test/metadata"}
              ])
          end
        end
      end)

      assert %{discovered: 2, created: 1, updated: 1, errors: []} =
               ModelDiscovery.reload_api(provider, api)

      if preset == "sglang" do
        assert_received "/v1/models"
        assert_received "/model_info"

        if unquote(failure) in [:unsupported, :method_not_allowed] do
          assert_received "/get_model_info"
        end

        refute_received _
      end

      model = ProviderModel.get_by_provider_and_model(provider.id, "listed-model")
      assert model.enabled
      assert model.metadata[preset] == known
      assert model.metadata["local_note"] == "keep"
      assert [surface] = model.surfaces
      assert surface.metadata[preset] == known
      assert surface.metadata["surface_note"] == "keep"
      new_model = ProviderModel.get_by_provider_and_model(provider.id, "new-model")
      refute Map.has_key?(new_model.metadata, preset)
    end
  end

  defp provider_api(preset, base_url) do
    {:ok, provider} =
      Provider.create(%{
        name: "metadata-#{preset}",
        preset_key: preset,
        credential: "metadata-discovery-key",
        default_headers: %{"x-provider-header" => "provider"}
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: base_url,
        default_headers: %{"x-api-header" => "api"},
        model_discovery_path: "/models"
      })

    {provider, api}
  end

  defp assert_headers(request) do
    assert ["Bearer test-discovery-key"] = HTTP.Headers.get_all(request.headers, "authorization")
    assert ["provider"] = HTTP.Headers.get_all(request.headers, "x-provider-header")
    assert ["api"] = HTTP.Headers.get_all(request.headers, "x-api-header")
  end

  defp raw_model(model_id) do
    %{"id" => model_id, "object" => "model", "owned_by" => "upstream", "max_model_len" => 4096}
  end

  defp json(body), do: HTTP.Test.json(body)
end
