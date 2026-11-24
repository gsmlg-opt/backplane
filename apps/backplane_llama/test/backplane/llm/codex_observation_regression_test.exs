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
          {:upstream_req, upstream.request_path, upstream.query_string, body,
           upstream.req_headers}
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

  test "respects observability disable setting and never leaks history/notes content into logs",
       %{
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

  for endpoint <- ["responses", "responses/compact"],
      protocol <- [:json, :sse],
      framing <- [:length, :chunked] do
    @tag matrix: {endpoint, protocol, framing}
    test "#{endpoint} observes #{protocol} with #{framing} transfer by content type", %{
      token: token,
      matrix: {endpoint, protocol, framing}
    } do
      json =
        ~s({"id":"resp_matrix","status":"completed","usage":{"input_tokens":23,"output_tokens":7}})

      body =
        case {protocol, endpoint} do
          {:json, _} ->
            json

          {:sse, "responses"} ->
            terminal =
              "event: response.completed\n" <>
                ~s(data: {"type":"response.completed","response":#{json}}\n\n)

            if framing == :length do
              delta =
                ~s(event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":") <>
                  String.duplicate("a", 50_000) <> ~s("}\n\n)

              :binary.copy(delta, 22) <> terminal
            else
              terminal
            end

          {:sse, "responses/compact"} ->
            ~s(data: {"usage":{"prompt_tokens":23,"completion_tokens":7}}\n\n)
        end

      parent = self()

      Application.put_env(:backplane_llama, :usage_accumulator_factory, fn proto ->
        pid = Backplane.LLM.UsageAccumulator.new(proto)
        send(parent, {:observed_acc, pid})
        pid
      end)

      server =
        BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
          upstream =
            put_resp_content_type(
              upstream,
              if(protocol == :json, do: "application/json", else: "text/event-stream")
            )

          if framing == :length do
            send_resp(upstream, 200, body)
          else
            upstream = send_chunked(upstream, 200)
            <<left::binary-size(17), right::binary>> = body
            {:ok, upstream} = chunk(upstream, left)
            {:ok, upstream} = chunk(upstream, right)
            upstream
          end
        end)

      {provider, _api} = create_codex_provider("r5-matrix", server.port)
      path = "/v1/providers/#{provider.name}/#{endpoint}"

      result =
        conn(:post, path, ~s({"input":"hello"}))
        |> put_req_header("authorization", "Bearer #{token}")
        |> OpenAICodexProxyPlug.call([])

      assert result.resp_body == body
      assert result.status == 200
      assert_received {:observed_acc, pid}
      assert_accumulator_stopped(pid)
      flush_logs!()
      [log] = fetch_logs(path)
      assert log.stream == (protocol == :sse)
      assert log.input_tokens == 23
      assert log.output_tokens == 7
    end
  end

  for framing <- [:length, :chunked], failure <- [:error, :throw, :exit] do
    @tag failure: {framing, failure}
    test "cleans actual accumulator after downstream #{framing} adapter #{failure}", %{
      token: token,
      failure: {framing, failure}
    } do
      parent = self()

      Application.put_env(:backplane_llama, :usage_accumulator_factory, fn proto ->
        pid = Backplane.LLM.UsageAccumulator.new(proto)
        send(parent, {:observed_acc, pid})
        pid
      end)

      body = ~s({"id":"resp_cleanup","status":"completed","usage":{"input_tokens":3}})

      server =
        BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
          send(parent, :r6_submitted)
          upstream = put_resp_content_type(upstream, "application/json")

          if framing == :length do
            send_resp(upstream, 200, body)
          else
            upstream = send_chunked(upstream, 200)
            {:ok, upstream} = chunk(upstream, body)
            upstream
          end
        end)

      {provider, _} = create_codex_provider("r6-exception", server.port)
      path = "/v1/providers/#{provider.name}/responses"

      request =
        conn(:post, path, ~s({"input":"hello"}))
        |> put_req_header("authorization", "Bearer #{token}")

      {_, adapter_state} = request.adapter
      request = %{request | adapter: {Backplane.Test.RaisingCodexAdapter, adapter_state}}

      Process.put(:r6_failure_kind, failure)

      {kind, reason, stack} =
        try do
          OpenAICodexProxyPlug.call(request, [])
          flunk("expected downstream failure")
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        after
          Process.delete(:r6_failure_kind)
        end

      assert kind == failure

      if failure == :error do
        assert %RuntimeError{message: "downstream write failed"} = reason
      else
        assert reason == :downstream_write_failed
      end

      assert [{Backplane.Test.RaisingCodexAdapter, _, _, _} | _] = stack
      assert_received :r6_submitted
      refute_received :r6_submitted
      assert_received {:observed_acc, pid}
      assert_accumulator_stopped(pid)
      flush_logs!()
      [log] = fetch_logs(path)
      assert log.outcome == "error"
    end
  end

  test "stops observation after a returned upstream transport error", %{token: token} do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
          )

        receive do
          :observing -> :ok
        after
          2_000 -> raise "observer did not initialize"
        end

        :ok = :gen_tcp.send(socket, "1\r\nx\r\n")
        :gen_tcp.close(socket)
      end)

    parent = self()

    Application.put_env(:backplane_llama, :usage_accumulator_factory, fn proto ->
      pid = Backplane.LLM.UsageAccumulator.new(proto)
      send(parent, {:observed_acc, pid})
      send(peer.pid, :observing)
      pid
    end)

    {provider, _} = create_codex_provider("r6-transport", port)
    path = "/v1/providers/#{provider.name}/responses"

    result =
      conn(:post, path, "{}")
      |> put_req_header("authorization", "Bearer #{token}")
      |> OpenAICodexProxyPlug.call([])

    assert result.private[:relayixir_proxy_error]
    assert :ok = Task.await(peer, 2_000)
    assert_received {:observed_acc, pid}
    assert_accumulator_stopped(pid)
    flush_logs!()
    [log] = fetch_logs(path)
    assert log.outcome == "error"
  end

  test "stops observation after downstream returns closed", %{token: token} do
    parent = self()

    Application.put_env(:backplane_llama, :usage_accumulator_factory, fn proto ->
      pid = Backplane.LLM.UsageAccumulator.new(proto)
      send(parent, {:observed_acc, pid})
      pid
    end)

    server =
      BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
        upstream = upstream |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, upstream} = chunk(upstream, "data: {}\n\n")
        upstream
      end)

    {provider, _} = create_codex_provider("r6-disconnect", server.port)
    path = "/v1/providers/#{provider.name}/responses"
    request = conn(:post, path, "{}") |> put_req_header("authorization", "Bearer #{token}")
    {_, adapter_state} = request.adapter
    request = %{request | adapter: {Backplane.Test.RaisingCodexAdapter, adapter_state}}
    Process.put(:r6_disconnect, true)

    try do
      result = OpenAICodexProxyPlug.call(request, [])
      assert result.private[:relayixir_downstream_disconnected]
    after
      Process.delete(:r6_disconnect)
    end

    assert_received {:observed_acc, pid}
    assert_accumulator_stopped(pid)
    flush_logs!()
    [log] = fetch_logs(path)
    assert log.outcome == "cancelled"
  end

  for {content_type, encoding} <- [
        {"application/octet-stream", nil},
        {"application/json", "gzip"},
        {"application/json-invalid", nil}
      ] do
    @tag unsupported: {content_type, encoding}
    test "keeps usage unknown for #{content_type} #{encoding}", %{
      token: token,
      unsupported: {content_type, encoding}
    } do
      parent = self()

      Application.put_env(:backplane_llama, :usage_accumulator_factory, fn _ ->
        send(parent, :unexpected_observer)
      end)

      body = ~s({"usage":{"input_tokens":23,"output_tokens":7}})

      server =
        BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
          upstream = put_resp_content_type(upstream, content_type)

          upstream =
            if encoding,
              do: put_resp_header(upstream, "content-encoding", encoding),
              else: upstream

          send_resp(upstream, 200, body)
        end)

      {provider, _} = create_codex_provider("r5-unsupported", server.port)
      path = "/v1/providers/#{provider.name}/responses"

      result =
        conn(:post, path, "{}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OpenAICodexProxyPlug.call([])

      assert result.resp_body == body
      refute_received :unexpected_observer
      flush_logs!()
      [log] = fetch_logs(path)
      assert is_nil(log.input_tokens)
      assert is_nil(log.output_tokens)
    end
  end

  test "disabled observation creates no accumulator for Responses", %{token: token} do
    parent = self()

    Application.put_env(:backplane_llama, :usage_accumulator_factory, fn _ ->
      send(parent, :unexpected_observer)
    end)

    disable_observability_v2!()
    set_llm_observation_enabled(false)

    try do
      server =
        BackplaneLlama.Test.HTTPServer.open_any(fn upstream ->
          upstream
          |> put_resp_content_type("application/json")
          |> send_resp(200, ~s({"usage":{"input_tokens":23}}))
        end)

      {provider, _} = create_codex_provider("r5-disabled", server.port)
      path = "/v1/providers/#{provider.name}/responses"

      result =
        conn(:post, path, "{}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> OpenAICodexProxyPlug.call([])

      assert result.status == 200
      refute_received :unexpected_observer
      flush_logs!()
      assert fetch_logs(path) == []
    after
      set_llm_observation_enabled(true)
    end
  end

  defp set_llm_observation_enabled(enabled) do
    key = "observability.llm_proxy.enabled"
    :ok = Backplane.Settings.set(key, enabled)
    Backplane.Observability.Settings.refresh_key(key)

    if Process.whereis(Backplane.Observability.Settings),
      do: :sys.get_state(Backplane.Observability.Settings)

    assert Backplane.Observability.Settings.llm_proxy_enabled?() == enabled
  end

  defp assert_accumulator_stopped(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
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

defmodule Backplane.Test.RaisingCodexAdapter do
  @behaviour Plug.Conn.Adapter
  def send_resp(_state, _status, _headers, _body), do: fail_write()

  def chunk(_state, _body) do
    if Process.get(:r6_disconnect), do: {:error, :closed}, else: fail_write()
  end

  defp fail_write do
    case Process.get(:r6_failure_kind, :error) do
      :error -> raise "downstream write failed"
      :throw -> throw(:downstream_write_failed)
      :exit -> exit(:downstream_write_failed)
    end
  end

  defdelegate send_file(state, status, headers, path, offset, length), to: Plug.Adapters.Test.Conn
  defdelegate send_chunked(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate read_req_body(state, opts), to: Plug.Adapters.Test.Conn
  defdelegate inform(state, status, headers), to: Plug.Adapters.Test.Conn
  defdelegate upgrade(state, protocol, opts), to: Plug.Adapters.Test.Conn
  defdelegate push(state, path, headers), to: Plug.Adapters.Test.Conn
  defdelegate get_peer_data(state), to: Plug.Adapters.Test.Conn
  defdelegate get_sock_data(state), to: Plug.Adapters.Test.Conn
  defdelegate get_ssl_data(state), to: Plug.Adapters.Test.Conn
  defdelegate get_http_protocol(state), to: Plug.Adapters.Test.Conn
end
