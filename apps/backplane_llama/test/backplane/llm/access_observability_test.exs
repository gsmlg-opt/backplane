defmodule Backplane.LLM.AccessObservabilityTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.Embedding
  alias Backplane.LLM.{
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    ProxyRequest,
    RateLimiter,
    Router
  }

  alias Backplane.Observability.Context
  alias Backplane.Settings.Credentials

  @moduletag observability_v2: true

  setup do
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)
    Application.delete_env(:backplane, :auth_token)
    Application.delete_env(:backplane, :auth_tokens)

    Credentials.store("obs-anthropic-cred", "sk-ant-obs-test", "llm")
    Credentials.store("obs-openai-cred", "sk-openai-obs-test", "llm")
    Credentials.store("obs-embedding-cred", "sk-embed-obs-test", "llm")

    {:ok, anthropic_upstream} = start_upstream(__MODULE__.AnthropicUpstream)
    {:ok, openai_upstream} = start_upstream(__MODULE__.OpenaiUpstream)

    {:ok, anthropic_provider} =
      Provider.create(%{name: "obs-anthropic", credential: "obs-anthropic-cred"})

    {:ok, openai_provider} = Provider.create(%{name: "obs-openai", credential: "obs-openai-cred"})

    anthropic = setup_provider_api(anthropic_provider, :anthropic, anthropic_upstream.port, "claude-obs")
    openai = setup_provider_api(openai_provider, :openai, openai_upstream.port, "gpt-obs")

    {:ok, embedding} =
      Embedding.create_provider_with_model(%{
        "name" => "obs-embed",
        "credential" => "obs-embedding-cred",
        "enabled" => "true",
        "base_url" => "http://localhost:#{openai_upstream.port}",
        "default_headers" => "{}",
        "model" => "text-embedding-obs",
        "display_name" => "Obs Embedding",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      Provider.soft_delete(anthropic_provider)
      Provider.soft_delete(openai_provider)
      stop_upstream(anthropic_upstream)
      stop_upstream(openai_upstream)
      restore_env(:auth_token, auth_token)
      restore_env(:auth_tokens, auth_tokens)
    end)

    %{
      anthropic: anthropic,
      openai: openai,
      embedding: embedding,
      anthropic_provider: anthropic_provider,
      openai_provider: openai_provider
    }
  end

  test "records OpenAI non-stream success", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/chat/completions", %{
        "model" => openai.model,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 200
    flush_logs!()

    log = latest_log()
    assert log.operation == "chat_completions"
    assert log.outcome == "success"
    assert log.requested_model == openai.model
    assert log.input_tokens == 3
    assert log.output_tokens == 5
    assert is_binary(log.event_id)
    assert is_binary(log.request_id)
    assert log.raw_request == nil
    assert log.raw_response == nil
  end

  test "records Anthropic non-stream success", %{anthropic: anthropic} do
    conn =
      llm_request(:post, "/v1/messages", %{
        "model" => anthropic.model,
        "max_tokens" => 16,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 200
    flush_logs!()

    log = latest_log()
    assert log.operation == "messages"
    assert log.outcome == "success"
    assert log.api_surface == "anthropic"
    assert log.input_tokens == 4
    assert log.output_tokens == 6
  end

  test "records embedding success", %{embedding: embedding} do
    model_id = "obs-embed/#{embedding.model.model}"

    conn =
      llm_request(:post, "/v1/embeddings", %{
        "model" => model_id,
        "input" => "hello"
      })

    assert conn.status == 200
    flush_logs!()

    log = latest_log()
    assert log.operation == "embeddings"
    assert log.outcome == "success"
    assert log.requested_model == model_id
  end

  test "records unknown model routing error" do
    conn =
      llm_request(:post, "/v1/chat/completions", %{
        "model" => "missing/model",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 404
    flush_logs!()

    log = log_for_model("missing/model")
    assert log.outcome == "error"
    assert log.error_kind == "routing"
    assert log.status == 404
    assert log.provider_id == nil
  end

  test "records API surface mismatch", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/messages", %{
        "model" => openai.model,
        "max_tokens" => 16,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 400
    flush_logs!()

    log = log_for_model(openai.model)
    assert log.outcome == "error"
    assert log.error_kind == "routing"
    assert log.error_code == "api_type_mismatch"
    assert log.provider_name == "obs-openai"
  end

  test "records rate limit rejection", %{openai_provider: provider} do
    {:ok, provider} = Provider.update(provider, %{rpm_limit: 1})
    ModelResolver.clear_cache()

    body = %{"model" => "obs-openai/gpt-obs", "messages" => [%{"role" => "user", "content" => "hi"}]}

    assert llm_request(:post, "/v1/chat/completions", body).status == 200

    conn = llm_request(:post, "/v1/chat/completions", body)
    assert conn.status == 429
    flush_logs!()

    import Ecto.Query

    log =
      Backplane.Repo.one(
        from(l in ProxyRequest,
          where: l.status == 429,
          order_by: [desc: l.inserted_at],
          limit: 1
        )
      )
    assert log.outcome == "error"
    assert log.error_kind == "rate_limit"
    assert log.status == 429
  end

  test "records missing credential error" do
    cred = "obs-missing-cred-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(cred, "temporary-key", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "obs-no-cred-#{System.unique_integer([:positive])}",
        credential: cred
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:9"
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "ghost", source: :manual})

    {:ok, _} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    :ok = Credentials.delete(cred)
    ModelResolver.clear_cache()
    ModelResolver.clear_cache()

    conn =
      llm_request(:post, "/v1/chat/completions", %{
        "model" => "#{provider.name}/ghost",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 503
    flush_logs!()

    log = latest_log()
    assert log.error_kind == "auth"
    assert log.error_code == "credential_missing"
  end

  test "records upstream 500 error", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/chat/completions", %{
        "model" => openai.model,
        "messages" => [%{"role" => "user", "content" => "fail"}]
      })

    assert conn.status == 500
    flush_logs!()

    log = log_for_model(openai.model)
    assert log.outcome == "error"
    assert log.status == 500
  end

  test "records stream success with ttft and chunks", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/chat/completions", %{
        "model" => openai.model,
        "stream" => true,
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert conn.status == 200
    flush_logs!()

    log = log_for_model(openai.model)
    assert log.stream == true
    assert log.outcome == "success"
    assert log.stream_chunks >= 2
    assert is_integer(log.ttft_ms)
    assert is_integer(log.ttft_ms)
    assert log.finish_reason in ["stop", nil]
  end

  test "propagates trace context from conn", %{openai: openai} do
    context = Context.root(request_id: "req-obs-1", trace_id: String.duplicate("a", 32))

    conn =
      llm_request(
        :post,
        "/v1/chat/completions",
        %{"model" => openai.model, "messages" => [%{"role" => "user", "content" => "hi"}]},
        context
      )

    assert conn.status == 200
    flush_logs!()

    log = latest_log()
    assert log.request_id == "req-obs-1"
    assert log.trace_id == String.duplicate("a", 32)
  end

  defp llm_request(method, path, body, context \\ nil) do
    payload = Jason.encode!(body)

    conn(method, path, payload)
    |> put_req_header("content-type", "application/json")
    |> then(fn conn -> if context, do: Context.put(conn, context), else: conn end)
    |> Router.call(Router.init([]))
  end

  defp setup_provider_api(provider, api_surface, port, model_name) do
    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: api_surface,
        base_url: "http://localhost:#{port}"
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: model_name, source: :manual})

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()

    %{
      provider: provider,
      api: api,
      model: "#{provider.name}/#{model_name}"
    }
  end

  defp start_upstream(module) do
    {:ok, pid} = Bandit.start_link(plug: module, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, %{pid: pid, port: port}}
  end

  defp stop_upstream(%{pid: pid}) do
    ThousandIsland.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_env(key, value), do: Application.put_env(:backplane, key, value)

  defmodule AnthropicUpstream do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/v1/messages" do
      send_json(conn, 200, %{
        "id" => "msg_obs",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "ok"}],
        "model" => conn.body_params["model"],
        "usage" => %{"input_tokens" => 4, "output_tokens" => 6}
      })
    end

    match _, do: send_resp(conn, 404, "")

    defp send_json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  defmodule OpenaiUpstream do
    use Plug.Router
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      if get_in(conn.body_params, ["messages", Access.at(0), "content"]) == "fail" do
        send_json(conn, 500, %{"error" => %{"message" => "upstream failed"}})
      else
        if conn.body_params["stream"] do
          stream(conn)
        else
          send_json(conn, 200, %{
            "id" => "chatcmpl_obs",
            "object" => "chat.completion",
            "model" => conn.body_params["model"],
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 5, "total_tokens" => 8}
          })
        end
      end
    end

    post "/v1/embeddings" do
      send_json(conn, 200, %{
        "object" => "list",
        "data" => [%{"index" => 0, "embedding" => [0.1, 0.2]}],
        "model" => conn.body_params["model"],
        "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
      })
    end

    match _, do: send_resp(conn, 404, "")

    defp stream(conn) do
      chunks = [
        ~s({"id":"chatcmpl_obs","choices":[{"delta":{"content":"hi"},"finish_reason":null}]}),
        ~s({"id":"chatcmpl_obs","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}})
      ]

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = chunk(conn, "data: #{chunk}\n\n")
        conn
      end)
    end

    defp send_json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end
end
