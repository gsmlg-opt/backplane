defmodule Backplane.LLM.RouterModelsMetadataTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Test

  alias Backplane.LLM.{
    AutoModel,
    AutoModelRoute,
    AutoModelTarget,
    ModelAlias,
    ModelMetadata,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    Router
  }

  alias Backplane.Settings.Credentials

  defmodule CodexUpstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(%{method: "GET", path_info: ["models"]} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"models":[{"slug":"gpt-codex"}]}))
    end

    def call(%{method: "POST", path_info: ["responses"]} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(201, body)
    end
  end

  setup do
    auth_config =
      Enum.map([:auth_token, :auth_tokens], &{&1, Application.get_env(:backplane, &1)})

    Enum.each(auth_config, fn {key, _value} -> Application.delete_env(:backplane, key) end)

    on_exit(fn ->
      Enum.each(auth_config, fn
        {key, nil} -> Application.delete_env(:backplane, key)
        {key, value} -> Application.put_env(:backplane, key, value)
      end)
    end)

    ModelResolver.clear_cache()
    {:ok, _} = Credentials.store("router-models-cred", "test-models-key", "llm")

    {:ok, _} =
      Credentials.store_device_token(
        "router-models-codex-cred",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "test-codex-token",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "test-account"}
      )

    :ok = Backplane.Settings.set(ModelAlias.setting_key(), %{})

    for name <- AutoModel.built_in_names() do
      :ok = Backplane.Settings.set("llm.auto_models.#{name}.targets", [])
    end

    :ok
  end

  test "normalizes merged model metadata with enabled OpenAI surface taking precedence" do
    target =
      create_target("dual", "shared",
        preset_key: "openrouter",
        metadata: %{"context_length" => 4096, "model_only" => true},
        surface_metadata: %{
          "context_length" => 128_000,
          "architecture" => %{"input_modalities" => ["text", "image"]},
          "supported_parameters" => ["tools", "reasoning"]
        }
      )

    add_surface(target, :anthropic, %{"context_length" => 8192})
    body = listing()
    entry = data_entry(body, "dual/shared")

    assert entry["metadata"]["context_window"] == 128_000
    assert entry["metadata"]["supports_tool_calling"]
    assert entry["metadata"]["supports_reasoning"]
    assert entry["metadata"]["input_modalities"] == ["text", "image"]
    assert entry["metadata"]["raw"]["model_only"]
    assert entry["metadata"]["raw"]["context_length"] == 128_000

    assert entry["metadata"] ==
             ModelMetadata.normalize(
               "openrouter",
               Map.merge(target.model.metadata, target.surface.metadata)
             )

    assert Enum.count(body["data"], &(&1["id"] == "dual/shared")) == 1
  end

  test "Codex slugs preserve provider prefixes and aliases and resolve to Responses targets" do
    create_target("responses", "reasoner",
      metadata: %{"context_window" => 32768},
      display_name: "Reasoner"
    )

    {:ok, _alias} = ModelAlias.put("coding", "reasoner")
    body = listing()

    assert Enum.map(body["models"], & &1["slug"]) == ["coding", "responses/reasoner"]
    refute Enum.any?(body["models"], &(&1["slug"] == "reasoner"))

    for descriptor <- body["models"] do
      assert data_entry(body, descriptor["slug"])
      assert {:ok, provider, "reasoner"} = ModelResolver.resolve(:openai, descriptor["slug"])
      assert provider.name == "responses"
      assert descriptor["supported_in_api"] == true
      assert is_integer(descriptor["priority"])
      assert descriptor["context_window"] == 32768
      assert descriptor["supported_reasoning_levels"] == []
      assert descriptor["support_verbosity"] == false
    end

    assert Enum.find(body["models"], &(&1["slug"] == "responses/reasoner"))["display_name"] ==
             "Reasoner"
  end

  test "auto and custom aliases inherit the resolver's selected target, not a fallback" do
    selected = create_target("first", "selected", metadata: %{"context_window" => 4096})
    fallback = create_target("second", "fallback", metadata: %{"context_window" => 65536})
    route = AutoModelRoute.get_by_model_and_surface("fast", :openai)

    for {target, priority} <- [{selected, 0}, {fallback, 1}] do
      {:ok, _target} =
        AutoModelTarget.create(%{
          auto_model_route_id: route.id,
          provider_model_surface_id: target.surface.id,
          priority: priority
        })
    end

    {:ok, _alias} = ModelAlias.put("coding", "fast")
    body = listing()

    for id <- ["fast", "coding"] do
      assert {:ok, provider, "selected"} = ModelResolver.resolve(:openai, id)
      assert provider.id == selected.provider.id
      assert data_entry(body, id)["metadata"]["context_window"] == 4096
      assert Enum.find(body["models"], &(&1["slug"] == id))["context_window"] == 4096
    end

    {:ok, _} = ProviderModelSurface.update(selected.surface, %{enabled: false})
    body = listing()

    for id <- ["fast", "coding"] do
      assert {:ok, provider, "fallback"} = ModelResolver.resolve(:openai, id)
      assert provider.id == fallback.provider.id
      assert data_entry(body, id)["metadata"]["context_window"] == 65536
    end
  end

  test "Anthropic and chat-only entries remain in data but not in Codex models" do
    create_target("anthropic", "claude",
      api_surface: :anthropic,
      metadata: %{"context_window" => 8192}
    )

    create_target("chat", "chat-only", native_protocols: [:openai_chat_completions])
    {:ok, _alias} = ModelAlias.put("writing", "claude")
    {:ok, _alias} = ModelAlias.put("chatting", "chat-only")
    body = listing()

    assert body["models"] == []
    assert data_entry(body, "anthropic/claude")["metadata"]["context_window"] == 8192
    assert data_entry(body, "writing")["metadata"]["context_window"] == 8192
    assert data_entry(body, "chat/chat-only")
    assert data_entry(body, "chatting")
  end

  test "a chat-only selected alias target does not inherit Responses from a fallback" do
    selected = create_target("chat", "chat-only", native_protocols: [:openai_chat_completions])
    fallback = create_target("responses", "responses-only")
    route = AutoModelRoute.get_by_model_and_surface("fast", :openai)

    for {target, priority} <- [{selected, 0}, {fallback, 1}] do
      {:ok, _target} =
        AutoModelTarget.create(%{
          auto_model_route_id: route.id,
          provider_model_surface_id: target.surface.id,
          priority: priority
        })
    end

    {:ok, _alias} = ModelAlias.put("coding", "fast")
    body = listing()
    assert data_entry(body, "fast")
    assert data_entry(body, "coding")
    assert Enum.map(body["models"], & &1["slug"]) == ["responses/responses-only"]
  end

  test "unknown model metadata preserves raw fields without invented context" do
    create_target("custom", "vision-reasoner", metadata: %{"unrecognized_limit" => 999})
    body = listing()
    metadata = data_entry(body, "custom/vision-reasoner")["metadata"]

    assert metadata == %{"raw" => %{"unrecognized_limit" => 999}}
    refute Map.has_key?(hd(body["models"]), "context_window")
  end

  test "disabled providers, models, surfaces and APIs exclude their models and aliases" do
    for disabled <- [:provider, :model, :surface, :api] do
      target = create_target("disabled-#{disabled}", "model-#{disabled}")
      {:ok, _alias} = ModelAlias.put("alias-#{disabled}", target.model.model)

      result =
        case disabled do
          :provider -> Provider.update(target.provider, %{enabled: false})
          :model -> ProviderModel.update(target.model, %{enabled: false})
          :surface -> ProviderModelSurface.update(target.surface, %{enabled: false})
          :api -> ProviderApi.update(target.api, %{enabled: false})
        end

      assert {:ok, _} = result
    end

    assert listing()["data"] == []
    assert listing()["models"] == []
  end

  test "disabled OpenAI surface falls back to enabled Anthropic metadata for data only" do
    target = create_target("dual", "shared", metadata: %{"context_window" => 4096})
    add_surface(target, :anthropic, %{"context_window" => 8192})
    {:ok, _} = ProviderModelSurface.update(target.surface, %{enabled: false})
    {:ok, _alias} = ModelAlias.put("writing", "shared")
    body = listing()

    assert body["models"] == []

    for id <- ["dual/shared", "writing"] do
      assert data_entry(body, id)["metadata"]["context_window"] == 8192
    end
  end

  test "openai-codex preset is listed in generic data but never generic Codex models" do
    target = create_target("codex", "gpt-codex", preset_key: "openai-codex")
    {:ok, _alias} = ModelAlias.put("coding", target.model.model)
    body = listing()

    assert data_entry(body, "codex/gpt-codex")
    assert data_entry(body, "coding")
    assert body["models"] == []
  end

  test "provider-specific Codex models and Responses endpoints remain transparent" do
    server = start_supervised!({Bandit, plug: CodexUpstream, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    backend_base_url = "http://127.0.0.1:#{port}"
    previous_backend = Application.get_env(:backplane, :openai_codex_backend_base_url)
    Application.put_env(:backplane, :openai_codex_backend_base_url, backend_base_url)

    on_exit(fn ->
      if is_nil(previous_backend) do
        Application.delete_env(:backplane, :openai_codex_backend_base_url)
      else
        Application.put_env(:backplane, :openai_codex_backend_base_url, previous_backend)
      end
    end)

    target = create_target("codex", "gpt-codex", preset_key: "openai-codex")
    {:ok, _api} = ProviderApi.update(target.api, %{base_url: backend_base_url})
    assert listing()["models"] == []

    models_response =
      conn(:get, "/v1/providers/codex/models")
      |> Backplane.LLM.ProxyPlug.call([])

    assert models_response.status == 200
    assert models_response.resp_body == ~s({"models":[{"slug":"gpt-codex"}]})

    request_body = ~s({"model":"gpt-codex","input":"unchanged"})

    responses_response =
      conn(:post, "/v1/providers/codex/responses", request_body)
      |> Backplane.LLM.ProxyPlug.call([])

    assert responses_response.status == 201
    assert responses_response.resp_body == request_body
  end

  defp listing do
    ModelResolver.clear_cache()
    response = Router.call(conn(:get, "/v1/models"), Router.init([]))
    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["object"] == "list"
    body
  end

  defp data_entry(body, id), do: Enum.find(body["data"], &(&1["id"] == id))

  defp create_target(name, model_id, opts \\ []) do
    credential =
      if opts[:preset_key] == "openai-codex",
        do: "router-models-codex-cred",
        else: "router-models-cred"

    {:ok, provider} =
      Provider.create(%{name: name, preset_key: opts[:preset_key], credential: credential})

    api_surface = Keyword.get(opts, :api_surface, :openai)

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: api_surface,
        base_url: "https://api.example.com/v1",
        native_protocols:
          Keyword.get(
            opts,
            :native_protocols,
            if(api_surface == :openai, do: [:openai_responses], else: [:anthropic_messages])
          )
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: model_id,
        display_name: opts[:display_name],
        source: :manual,
        metadata: Keyword.get(opts, :metadata, %{})
      })

    {:ok, surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        metadata: Keyword.get(opts, :surface_metadata, %{})
      })

    %{provider: provider, api: api, model: model, surface: surface}
  end

  defp add_surface(target, api_surface, metadata) do
    {:ok, api} =
      ProviderApi.create(%{
        provider_id: target.provider.id,
        api_surface: api_surface,
        base_url: "https://api.example.com"
      })

    {:ok, surface} =
      ProviderModelSurface.create(%{
        provider_model_id: target.model.id,
        provider_api_id: api.id,
        metadata: metadata
      })

    surface
  end
end
