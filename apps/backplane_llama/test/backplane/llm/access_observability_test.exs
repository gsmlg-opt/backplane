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

    anthropic =
      setup_provider_api(anthropic_provider, :anthropic, anthropic_upstream.port, "claude-obs")

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

    log = log_for_request(conn)
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

  test "records shared Responses facts for non-streaming business logs", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/responses", %{
        "model" => openai.model,
        "input" => "hi"
      })

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["id"] == "resp_obs"
    flush_logs!()

    log = log_for_request(conn)
    assert log.operation == "responses"
    assert log.input_tokens == 12
    assert log.output_tokens == 7
    assert log.cached_tokens == 4
    assert log.reasoning_tokens == 2
    assert log.provider_request_id == "resp_obs"

    assert get_in(log.metadata, ["protocol_observation", "implementation"]) =~
             "OpenAIResponsesObserver"

    assert get_in(log.metadata, ["protocol_observation", "protocol_terminal"]) == "completed"
  end

  test "records shared Responses facts for SSE including trailing usage", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/responses", %{
        "model" => openai.model,
        "input" => "hi",
        "stream" => true
      })

    assert conn.status == 200
    assert conn.resp_body =~ "response.completed"
    flush_logs!()

    log = log_for_request(conn)
    assert log.stream == true
    assert log.input_tokens == 6
    assert log.output_tokens == 3
    assert log.cached_tokens == 1
    assert log.reasoning_tokens == 1
    assert log.provider_request_id == "resp_obs_stream"
    assert get_in(log.metadata, ["protocol_observation", "terminal_count"]) == 1
  end

  test "uses shared sanitized Responses error classification", %{openai: openai} do
    conn = llm_request(:post, "/v1/responses", %{"model" => openai.model, "input" => "fail"})
    assert conn.status == 400
    flush_logs!()

    log = log_for_request(conn)
    assert log.outcome == "error"
    assert log.error_code == "bad_fixture"
    assert log.error_reason == "invalid_request_error"
    refute log.error_reason =~ "secret"
  end

  test "preserves malformed native body and records incomplete observation", %{openai: openai} do
    conn =
      llm_request(:post, "/v1/responses", %{"model" => openai.model, "input" => "malformed"})

    assert conn.status == 200
    assert conn.resp_body == "{malformed"
    flush_logs!()

    log = log_for_request(conn)
    assert log.input_tokens == nil
    assert get_in(log.metadata, ["protocol_observation", "observation_status"]) == "incomplete"
  end

  test "consumes malformed nested Responses facts without changing native bytes", %{
    openai: openai
  } do
    conn =
      llm_request(:post, "/v1/responses", %{
        "model" => openai.model,
        "input" => "malformed-nested"
      })

    expected =
      ~S({"id":"resp_obs_malformed","status":"completed","output":[{"type":"function_call","id":"fc_bad","name":"lookup","arguments":null}],"usage":{"input_tokens":2,"output_tokens":1,"input_tokens_details":1}})

    assert conn.status == 200
    assert conn.resp_body == expected
    flush_logs!()

    log = log_for_request(conn)
    assert log.input_tokens == 2
    assert log.output_tokens == 1
    assert get_in(log.metadata, ["protocol_observation", "observation_status"]) == "incomplete"
    assert get_in(log.metadata, ["protocol_observation", "usage_status"]) == "partial"
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

    log = log_for_request(conn)
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

    log = log_for_request(conn)
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

    log = log_for_request(conn)
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

    log = log_for_request(conn)
    assert log.outcome == "error"
    assert log.error_kind == "routing"
    assert log.error_code == "api_type_mismatch"
    assert log.provider_name == "obs-openai"
  end

  test "records rate limit rejection", %{openai_provider: provider} do
    {:ok, _provider} = Provider.update(provider, %{rpm_limit: 1})
    ModelResolver.clear_cache()

    body = %{
      "model" => "obs-openai/gpt-obs",
      "messages" => [%{"role" => "user", "content" => "hi"}]
    }

    assert llm_request(:post, "/v1/chat/completions", body).status == 200

    conn = llm_request(:post, "/v1/chat/completions", body)
    assert conn.status == 429
    flush_logs!()

    log = log_for_request(conn)

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

    log = log_for_request(conn)
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

    log = log_for_request(conn)
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

    log = log_for_request(conn)
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

    log = log_for_request(conn)
    assert log.request_id == "req-obs-1"
    assert log.trace_id == String.duplicate("a", 32)
  end

  defp llm_request(method, path, body, context \\ nil) do
    payload = Jason.encode!(body)
    context = context || Context.root()

    conn(method, path, payload)
    |> put_req_header("content-type", "application/json")
    |> Context.put(context)
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

    post "/v1/responses" do
      cond do
        conn.body_params["input"] == "fail" ->
          send_json(conn, 400, %{
            "error" => %{
              "type" => "invalid_request_error",
              "code" => "bad_fixture",
              "message" => "secret prompt must not be logged"
            }
          })

        conn.body_params["input"] == "malformed" ->
          conn |> put_resp_content_type("application/json") |> send_resp(200, "{malformed")

        conn.body_params["input"] == "malformed-nested" ->
          body =
            ~S({"id":"resp_obs_malformed","status":"completed","output":[{"type":"function_call","id":"fc_bad","name":"lookup","arguments":null}],"usage":{"input_tokens":2,"output_tokens":1,"input_tokens_details":1}})

          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        conn.body_params["stream"] ->
          responses_stream(conn)

        true ->
          send_json(conn, 200, %{
            "id" => "resp_obs",
            "object" => "response",
            "status" => "completed",
            "output" => [],
            "usage" => %{
              "input_tokens" => 12,
              "input_tokens_details" => %{"cached_tokens" => 4},
              "output_tokens" => 7,
              "output_tokens_details" => %{"reasoning_tokens" => 2},
              "total_tokens" => 19
            }
          })
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

    defp responses_stream(conn) do
      content_done =
        ~s({"type":"response.output_text.done","text":"ok"})

      protocol_done =
        ~s({"type":"response.completed","response":{"id":"resp_obs_stream","status":"completed","usage":{"input_tokens":6,"input_tokens_details":{"cached_tokens":1},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":9}}})

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      {:ok, conn} =
        chunk(conn, "event: response.output_text.done\r\ndata: #{content_done}\r\n\r\n")

      {:ok, conn} = chunk(conn, "data: #{protocol_done}\n\n")
      conn
    end

    defp send_json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end
end
