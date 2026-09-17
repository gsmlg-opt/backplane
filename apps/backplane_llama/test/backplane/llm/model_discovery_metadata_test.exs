defmodule Backplane.LLM.ModelDiscoveryMetadataTest do
  use BackplaneLlama.DataCase, async: false

  alias Backplane.LLM.{ModelDiscovery, Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings.Credentials

  defmodule RequestOptionsAdapter do
    def run(request) do
      send(self(), {:discovery_request, request})

      body =
        if String.ends_with?(request.url.path, "/models") do
          %{"data" => [%{"id" => "listed-model"}]}
        else
          %{"model_path" => "listed-model", "capabilities" => ["completion"]}
        end

      {request, Req.Response.new(status: 200, body: body)}
    end
  end

  setup do
    previous = Application.get_env(:backplane, :llm_model_discovery_req_options)

    Application.put_env(:backplane, :llm_model_discovery_req_options,
      plug: {Req.Test, __MODULE__},
      receive_timeout: 1234
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :llm_model_discovery_req_options, previous)
      else
        Application.delete_env(:backplane, :llm_model_discovery_req_options)
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

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "localhost"
      assert conn.port == 11434
      assert_headers(conn)
      send(owner, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/deployment/v1/models"} ->
          json(conn, %{"data" => [raw_model("llama:latest"), raw_model("llama:small")]})

        {"POST", "/deployment/api/show"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"model" => model} = Jason.decode!(body)
          assert model in ["llama:latest", "llama:small"]
          json(conn, supplemental)
      end
    end)

    assert %{discovered: 2, created: 2, errors: []} = ModelDiscovery.reload_api(provider, api)
    assert_received {"GET", "/deployment/v1/models"}
    assert_received {"POST", "/deployment/api/show"}
    assert_received {"POST", "/deployment/api/show"}
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

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "inference.example.test"
      assert_headers(conn)
      send(owner, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v1/models"} -> json(conn, %{"data" => [raw_model("served-alias")]})
        {"GET", "/model_info"} -> json(conn, supplemental)
      end
    end)

    assert %{discovered: 1, created: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
    assert_received {"GET", "/v1/models"}
    assert_received {"GET", "/model_info"}
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

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, conn.request_path)

      case conn.request_path do
        "/models" -> json(conn, %{"data" => [raw_model("base-model"), raw_model("adapter")]})
        "/model_info" -> json(conn, supplemental)
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

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert_headers(conn)
        send(owner, conn.request_path)

        case conn.request_path do
          "/deployment/v1/models" -> json(conn, %{"data" => [raw_model("listed-model")]})
          "/deployment/model_info" -> Plug.Conn.send_resp(conn, unquote(status), "unsupported")
          "/deployment/get_model_info" -> json(conn, supplemental)
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

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/v1/models" ->
            json(conn, %{"data" => [raw_model("listed-model")]})

          "/model_info" ->
            json(conn, %{
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

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v1/models" ->
          json(conn, %{"data" => [raw_model("source-model"), raw_model("served-model")]})

        "/model_info" ->
          json(conn, supplemental)
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

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/v1/models" -> json(conn, %{"data" => [raw_model("served-alias")]})
        "/model_info" -> json(conn, supplemental)
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

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, conn.request_path)
        assert conn.request_path == "/v1/models"
        json(conn, [])
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

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/models"
        send(owner, :models_requested)
        json(conn, %{"data" => [raw_model("listed-model")]})
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
      connection = [proxy: {:http, "proxy.example.test", 3128, []}]

      Application.put_env(:backplane, :llm_model_discovery_req_options,
        adapter: RequestOptionsAdapter,
        receive_timeout: 1234,
        connect_options: connection
      )

      assert %{discovered: 1, errors: []} = ModelDiscovery.reload_api(provider, api)
      assert_received {:discovery_request, list_request}
      assert_received {:discovery_request, supplemental_request}
      refute_received {:discovery_request, _}
      assert list_request.url.path == "/deployment/v1/models"

      for request <- [list_request, supplemental_request] do
        assert request.options[:receive_timeout] == 1234
        assert request.options[:connect_options] == connection
        assert request.url.host == "models.example.test"
        assert request.url.port == 8443
        assert request.headers["authorization"] == ["Bearer test-discovery-key"]
      end

      assert supplemental_request.options[:redirect] == false
      assert supplemental_request.options[:retry] == false

      if preset == "ollama" do
        assert supplemental_request.url.path == "/deployment/api/show"
        assert supplemental_request.method == :post
        assert Jason.decode!(supplemental_request.body) == %{"model" => "listed-model"}
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

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, conn.request_path)

        if conn.request_path == "/v1/models" do
          json(conn, %{"data" => [raw_model("listed-model"), raw_model("new-model")]})
        else
          case unquote(failure) do
            :unsupported ->
              Plug.Conn.send_resp(conn, 404, "unsupported")

            :method_not_allowed ->
              Plug.Conn.send_resp(conn, 405, "unsupported")

            :unauthorized ->
              Plug.Conn.send_resp(conn, 401, "private error")

            :forbidden ->
              Plug.Conn.send_resp(conn, 403, "private error")

            :server_error ->
              Plug.Conn.send_resp(conn, 500, "private error")

            :transport ->
              Req.Test.transport_error(conn, :timeout)

            :invalid ->
              json(conn, %{"error" => "private error"})

            :empty ->
              json(conn, %{})

            :non_map ->
              json(conn, [])

            :malformed_json ->
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(200, "{")

            :redirect ->
              conn
              |> Plug.Conn.put_resp_header("location", "https://untrusted.example.test/metadata")
              |> Plug.Conn.send_resp(302, "")
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

  defp assert_headers(conn) do
    assert ["Bearer test-discovery-key"] = Plug.Conn.get_req_header(conn, "authorization")
    assert ["provider"] = Plug.Conn.get_req_header(conn, "x-provider-header")
    assert ["api"] = Plug.Conn.get_req_header(conn, "x-api-header")
  end

  defp raw_model(model_id) do
    %{"id" => model_id, "object" => "model", "owned_by" => "upstream", "max_model_len" => 4096}
  end

  defp json(conn, body), do: Req.Test.json(conn, body)
end
