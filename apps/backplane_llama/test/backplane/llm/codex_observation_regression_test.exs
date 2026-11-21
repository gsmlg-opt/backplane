defmodule Backplane.LLM.CodexObservationRegressionTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test
  import Backplane.Auth.Fixtures

  alias Backplane.LLM.{
    OpenAICodexProxyPlug,
    Provider,
    ProviderApi,
    ProxyRequest,
    RateLimiter
  }

  alias Backplane.Observability.Context
  alias Backplane.Repo
  alias Backplane.Settings.{Credentials, TokenCache}

  @moduletag observability_v2: true

  setup do
    TokenCache.clear()
    RateLimiter.reset()

    prev_factory = Application.get_env(:backplane_llama, :usage_accumulator_factory)

    on_exit(fn ->
      if prev_factory do
        Application.put_env(:backplane_llama, :usage_accumulator_factory, prev_factory)
      else
        Application.delete_env(:backplane_llama, :usage_accumulator_factory)
      end
    end)

    {:ok, _} =
      Credentials.store_device_token(
        "f3-codex-token",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "id_token" => "id-tok",
          "access_token" => "codex-secret-token",
          "refresh_token" => "codex-refresh",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "acc-f3"}
      )

    user = auth_user_fixture!()

    client =
      oauth_client_fixture!(
        resources: [:v1],
        scopes: ["llm::invoke", "llm::models", "llm::codex-history-notes"]
      )

    token =
      resource_access_token_fixture!(
        user,
        client,
        ["llm::invoke", "llm::models", "llm::codex-history-notes"],
        :v1
      )

    %{token: token.value, user: user}
  end

  test "records one access log with upstream usage for Codex SSE and compact responses while preserving compressed bytes",
       %{token: token} do
    parent = self()
    zstd_payload = <<0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58, 0x41, 0x00, 0x00, 0x7B, 0x7D>>

    sse_body =
      "event: response.created\n" <>
        ~s(data: {"type":"response.created","response":{"id":"resp_f3_sse","model":"gpt-5.5","status":"in_progress"}}\n\n) <>
        "event: response.completed\n" <>
        ~s(data: {"type":"response.completed","response":{"id":"resp_f3_sse","model":"gpt-5.5","status":"completed","usage":{"input_tokens":123,"output_tokens":45,"input_tokens_details":{"cached_tokens":12},"output_tokens_details":{"reasoning_tokens":7}}}}\n\n)

    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        {:ok, body, upstream} = read_body(upstream)

        send(
          parent,
          {:upstream_req, upstream.request_path, upstream.query_string, body, upstream.req_headers}
        )

        case upstream.request_path do
          "/responses" ->
            upstream =
              upstream
              |> put_resp_content_type("text/event-stream")
              |> put_resp_header("x-request-id", "req_f3_sse")
              |> send_chunked(200)

            {:ok, upstream} = chunk(upstream, sse_body)
            upstream

          "/responses/compact" ->
            upstream
            |> put_resp_content_type("application/json")
            |> put_resp_header("x-request-id", "req_f3_compact")
            |> send_resp(
              200,
              Formata.JSON.encode!(%{
                "id" => "cmp_1",
                "usage" => %{"input_tokens" => 50, "output_tokens" => 10}
              })
            )
        end
      end)

    {provider, _api} = create_codex_provider("f3-codex", server.port)
    ctx_sse = Context.root()

    resp =
      conn(:post, "/v1/providers/#{provider.name}/responses?trace=1", zstd_payload)
      |> Context.put(ctx_sse)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("content-encoding", "zstd")
      |> put_req_header("content-length", Integer.to_string(byte_size(zstd_payload)))
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert resp.status == 200
    assert resp.resp_body == sse_body

    assert_received {:upstream_req, "/responses", "trace=1", ^zstd_payload, req_headers}
    assert {"content-encoding", "zstd"} in req_headers

    flush_logs!()
    logs = fetch_logs("/v1/providers/#{provider.name}/responses")
    assert length(logs) == 1
    [log] = logs
    assert log.request_id == ctx_sse.request_id
    assert log.outcome == "success"
    assert log.status == 200
    assert log.stream == true
    assert log.provider_name == provider.name
    assert log.input_tokens == 123
    assert log.output_tokens == 45
    assert log.cached_tokens == 12
    assert log.reasoning_tokens == 7
    assert log.request_bytes == byte_size(zstd_payload)
    refute inspect(log) =~ "codex-secret-token"

    compact_resp =
      conn(:post, "/v1/providers/#{provider.name}/responses/compact", ~s({"input":"compact"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert compact_resp.status == 200
    flush_logs!()
    compact_logs = fetch_logs("/v1/providers/#{provider.name}/responses/compact")
    assert length(compact_logs) == 1
    [compact_log] = compact_logs
    assert compact_log.outcome == "success"
    assert compact_log.operation == "compact"
    assert compact_log.input_tokens == 50
    assert compact_log.output_tokens == 10
  end

  test "EOF without terminal event leaves usage unknown and does not fabricate completion", %{
    token: token
  } do
    server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/responses", fn upstream ->
        upstream =
          upstream
          |> put_resp_content_type("text/event-stream")
          |> send_chunked(200)

        {:ok, upstream} =
          chunk(
            upstream,
            ~s(data: {"type":"response.created","response":{"id":"resp_partial","status":"in_progress"}}\n\n)
          )

        upstream
      end)

    {provider, _api} = create_codex_provider("f3-eof", server.port)

    resp =
      conn(:post, "/v1/providers/#{provider.name}/responses", ~s({"input":"hi"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert resp.status == 200

    flush_logs!()
    [log] = fetch_logs("/v1/providers/#{provider.name}/responses")
    assert is_nil(log.input_tokens)
    assert is_nil(log.output_tokens)
    assert log.finish_reason == "interrupted"
    refute log.finish_reason in ["completed", "stop"]
  end

  test "classifies local rejections and upstream errors once, and observer failures never break forwarding",
       %{token: token} do
    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        case upstream.request_path do
          "/responses" ->
            upstream
            |> put_resp_content_type("application/json")
            |> send_resp(429, ~s({"error":{"code":"rate_limit"}}))

          _ ->
            upstream |> send_resp(200, ~s({"ok":true}))
        end
      end)

    {provider, _api} = create_codex_provider("f3-errors", server.port)

    missing =
      conn(:post, "/v1/providers/nonexistent-codex/responses", ~s({}))
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert missing.status == 404
    flush_logs!()
    [missing_log] = fetch_logs("/v1/providers/nonexistent-codex/responses")
    assert missing_log.outcome == "error"
    assert missing_log.status == 404
    assert missing_log.error_code == "provider_not_found"

    upstream_err =
      conn(:post, "/v1/providers/#{provider.name}/responses", ~s({"input":"hi"}))
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert upstream_err.status == 429
    flush_logs!()
    [err_log] = fetch_logs("/v1/providers/#{provider.name}/responses")
    assert err_log.outcome == "error"
    assert err_log.status == 429
    assert err_log.error_kind == "upstream_error"
    assert err_log.error_code == "upstream_rate_limited"

    Application.put_env(:backplane_llama, :usage_accumulator_factory, fn _proto ->
      raise "observer boom"
    end)

    ok_server =
      BackplaneLlama.Test.HTTPServer.open("POST", "/responses", fn upstream ->
        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, ~s({"id":"resp_still_ok","status":"completed"}))
      end)

    {ok_provider, _} = create_codex_provider("f3-resilient", ok_server.port)

    resilient =
      conn(:post, "/v1/providers/#{ok_provider.name}/responses", ~s({"input":"hi"}))
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert resilient.status == 200
    assert resilient.resp_body == ~s({"id":"resp_still_ok","status":"completed"})
  end

  test "respects observability disable setting and never leaks history/notes content into logs", %{
    token: token,
    user: user
  } do
    secret_note = "SUPER_PRIVATE_CODEX_NOTE_CONTENT_999"

    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        upstream
        |> put_resp_content_type("application/json")
        |> send_resp(200, Formata.JSON.encode!(%{"content" => secret_note}))
      end)

    {provider, _api} = create_codex_provider("f3-notes", server.port)

    narrow_client = oauth_client_fixture!(resources: [:v1], scopes: ["llm::invoke"])
    narrow_token = resource_access_token_fixture!(user, narrow_client, ["llm::invoke"], :v1)

    denied =
      conn(:post, "/v1/providers/#{provider.name}/alpha/notes/v2/read_file", ~s({"path":"a.md"}))
      |> put_req_header("authorization", "Bearer #{narrow_token.value}")
      |> OpenAICodexProxyPlug.call([])

    assert denied.status == 403

    allowed =
      conn(:post, "/v1/providers/#{provider.name}/alpha/notes/v2/read_file", ~s({"path":"a.md"}))
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert allowed.status == 200
    assert allowed.resp_body =~ secret_note

    flush_logs!()
    [note_log] = fetch_logs("/v1/providers/#{provider.name}/alpha/notes/v2/read_file")
    assert note_log.outcome == "success"
    assert note_log.operation == "codex.notes.read_file"
    refute inspect(note_log) =~ secret_note

    disable_observability_v2!()

    disabled_resp =
      conn(:get, "/v1/providers/#{provider.name}/models")
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert disabled_resp.status == 200
    flush_logs!()
    assert fetch_logs("/v1/providers/#{provider.name}/models") == []
  end

  defp create_codex_provider(name, port) do
    {:ok, provider} =
      Provider.create(%{
        name: name,
        preset_key: "openai-codex",
        api_type: :openai,
        api_url: "http://localhost:#{port}",
        credential: "f3-codex-token",
        models: []
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://localhost:#{port}",
        model_discovery_path: "/models"
      })

    {provider, api}
  end

  defp fetch_logs(path) do
    ProxyRequest
    |> where([l], l.path == ^path)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
  end
end
