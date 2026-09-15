defmodule Backplane.Api.LLMProtocolEndpointIntegrationTest do
  use Backplane.Api.DataCase, async: false

  alias Backplane.LLM.{
    LogWriter,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface,
    ProxyRequest,
    RateLimiter
  }

  alias Backplane.Settings.Credentials

  defmodule OpenAIUpstream do
    use Plug.Router

    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:match)
    plug(:dispatch)

    post "/v1/responses" do
      record_submission(conn)

      cond do
        conn.body_params["input"] == "chunked-json" ->
          chunked_json(conn, chunked_json_body(), true)

        conn.body_params["input"] == "chunked-overflow" ->
          chunked_json(conn, oversized_chunked_json_body(), false)

        conn.body_params["input"] == "error" ->
          conn
          |> Plug.Conn.put_resp_header("x-upstream-request-id", "upstream-error-123")
          |> send_json(400, %{
            "error" => %{
              "code" => "endpoint_bad_request",
              "type" => "invalid_request_error",
              "message" => "secret upstream detail"
            }
          })

        conn.body_params["input"] == "malformed" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "{malformed")

        conn.body_params["input"] == "refusal" ->
          send_json(conn, 200, %{
            "id" => "resp_endpoint_refusal",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "refusal", "refusal" => "not allowed"}]
              }
            ]
          })

        conn.body_params["input"] == "output-limit" ->
          send_json(conn, 200, %{
            "id" => "resp_endpoint_limit",
            "status" => "incomplete",
            "incomplete_details" => %{"reason" => "max_output_tokens"},
            "output" => []
          })

        conn.body_params["input"] == "truncated" ->
          truncated_stream(conn)

        conn.body_params["input"] == "disconnect" ->
          disconnect_stream(conn)

        conn.body_params["input"] == "early-stream" ->
          early_stream(conn)

        conn.body_params["stream"] == true ->
          completed_stream(conn)

        true ->
          body =
            ~S({"id":"resp_endpoint_1","object":"response","status":"completed","output":[{"type":"message","id":"msg_endpoint_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"endpoint output","annotations":[]}]}],"usage":{"input_tokens":11,"input_tokens_details":{"cached_tokens":3},"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":18}})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
      end
    end

    match _, do: Plug.Conn.send_resp(conn, 404, "")

    defp record_submission(conn) do
      Agent.update(Backplane.Api.LLMProtocolEndpointIntegrationTest.Store, fn captured ->
        %{
          captured
          | submissions: captured.submissions + 1,
            headers: conn.req_headers,
            body: conn.body_params
        }
      end)
    end

    defp completed_stream(conn) do
      conn = conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> send_chunked(200)

      output = ~S({"type":"response.output_text.done","text":"endpoint stream"})
      {:ok, conn} = chunk(conn, "event: response.output_text.done\r\ndata: #{output}\r\n\r\n")

      completion =
        ~S({"type":"response.completed","response":{"id":"resp_endpoint_stream","status":"completed","usage":{"input_tokens":6,"input_tokens_details":{"cached_tokens":1},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":9}}})

      {:ok, conn} = chunk(conn, "data: " <> binary_part(completion, 0, 57))
      {:ok, conn} = chunk(conn, binary_part(completion, 57, byte_size(completion) - 57) <> "\n\n")
      conn
    end

    defp chunked_json(conn, body, pause_before_completion?) do
      {first, rest} = String.split_at(body, 37)
      {second, third} = String.split_at(rest, 83)

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, first)
      {:ok, conn} = chunk(conn, second)

      if pause_before_completion? do
        test_pid =
          Agent.get(Backplane.Api.LLMProtocolEndpointIntegrationTest.Store, & &1.test_pid)

        send(test_pid, {:chunked_json_partial, self()})

        receive do
          :release_chunked_json -> :ok
        after
          2_000 -> raise "timed out waiting to complete chunked JSON response"
        end
      end

      {:ok, conn} = chunk(conn, third)
      conn
    end

    def chunked_json_body do
      ~S({"id":"resp_endpoint_chunked","object":"response","status":"completed","output":[{"type":"message","id":"msg_endpoint_chunked","status":"completed","role":"assistant","content":[{"type":"output_text","text":"chunked endpoint output","annotations":[]}]}],"usage":{"input_tokens":13,"input_tokens_details":{"cached_tokens":4},"output_tokens":9,"output_tokens_details":{"reasoning_tokens":3},"total_tokens":22}})
    end

    def oversized_chunked_json_body do
      ~S({"id":"resp_endpoint_overflow","status":"completed","output":[],"padding":") <>
        String.duplicate("x", 8_388_608) <>
        ~S(","usage":{"input_tokens":99,"output_tokens":88}})
    end

    defp truncated_stream(conn) do
      conn = conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> send_chunked(200)

      {:ok, conn} =
        chunk(
          conn,
          ~S(data: {"type":"response.output_text.delta","delta":"partial"}) <> "\n\n"
        )

      conn
    end

    defp disconnect_stream(conn) do
      conn = conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> send_chunked(200)

      {:ok, conn} =
        chunk(conn, ~S(data: {"type":"response.output_text.delta","delta":"first"}) <> "\n\n")

      Process.sleep(100)

      case chunk(
             conn,
             ~S(data: {"type":"response.output_text.delta","delta":"second"}) <> "\n\n"
           ) do
        {:ok, conn} -> conn
        {:error, :closed} -> conn
      end
    end

    defp early_stream(conn) do
      conn = conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> send_chunked(200)
      {first, second} = early_stream_events()
      {:ok, conn} = chunk(conn, first)

      test_pid = Agent.get(Backplane.Api.LLMProtocolEndpointIntegrationTest.Store, & &1.test_pid)
      send(test_pid, {:early_stream_partial, self()})

      receive do
        :release_early_stream -> :ok
      after
        2_000 -> raise "timed out waiting to complete early stream"
      end

      {:ok, conn} = chunk(conn, binary_part(second, 0, 41))
      {:ok, conn} = chunk(conn, binary_part(second, 41, byte_size(second) - 41))
      conn
    end

    def early_stream_body do
      early_stream_events() |> Tuple.to_list() |> IO.iodata_to_binary()
    end

    defp early_stream_events do
      unknown =
        ~S(event: provider.future) <>
          "\r\n" <>
          ~S(data: {"type":"provider.future","extension":{"snow":"雪"}}) <> "\r\n\r\n"

      completed =
        ~S(data: {"type":"response.completed","response":{"id":"resp_endpoint_early","status":"completed","usage":{"input_tokens":4,"output_tokens":2}}}) <>
          "\n\n"

      {unknown, completed}
    end

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  setup do
    auth_token = Application.get_env(:backplane, :auth_token)
    auth_tokens = Application.get_env(:backplane, :auth_tokens)

    observability_enabled =
      Application.get_env(:backplane_telemetry, :observability_v2_enabled)

    observability_llm_write =
      Application.get_env(:backplane_telemetry, :observability_v2_llm_write)

    observability_test_disabled =
      Application.get_env(:backplane_telemetry, :observability_v2_test_disabled)

    Application.put_env(:backplane, :auth_token, "endpoint-client-token")
    Application.delete_env(:backplane, :auth_tokens)
    Application.put_env(:backplane_telemetry, :observability_v2_enabled, true)
    Application.put_env(:backplane_telemetry, :observability_v2_llm_write, true)
    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, false)

    if is_nil(Process.whereis(:llm_proxy)) do
      start_supervised!({Backplane.Observability.Buffer, name: :llm_proxy, capacity: 8})
    end

    if is_nil(Process.whereis(LogWriter)) do
      start_supervised!({LogWriter, batch_size: 8, flush_interval_ms: 60_000})
    end

    LogWriter.detach()
    LogWriter.attach()

    test_pid = self()

    {:ok, store} =
      Agent.start_link(fn -> %{submissions: 0, headers: [], body: nil, test_pid: test_pid} end,
        name: __MODULE__.Store
      )

    {:ok, upstream} = Bandit.start_link(plug: OpenAIUpstream, port: 0)
    {:ok, {_ip, upstream_port}} = ThousandIsland.listener_info(upstream)

    {:ok, endpoint} = Bandit.start_link(plug: Backplane.Api.Endpoint, port: 0)
    {:ok, {_ip, endpoint_port}} = ThousandIsland.listener_info(endpoint)

    {:ok, _} = Credentials.store("endpoint-provider-key", "sk-endpoint-provider", "llm")

    {:ok, provider} =
      Provider.create(%{name: "endpoint-provider", credential: "endpoint-provider-key"})

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:#{upstream_port}",
        native_protocols: [:openai_responses]
      })

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "endpoint-model", source: :manual})

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    ModelResolver.clear_cache()
    RateLimiter.reset()

    on_exit(fn ->
      Provider.soft_delete(provider)
      Credentials.delete("endpoint-provider-key")
      stop_server(endpoint)
      stop_server(upstream)

      try do
        Agent.stop(store)
      catch
        :exit, _ -> :ok
      end

      restore_env(:auth_token, auth_token)
      restore_env(:auth_tokens, auth_tokens)
      LogWriter.detach()

      restore_env(
        :observability_v2_enabled,
        observability_enabled,
        :backplane_telemetry
      )

      restore_env(
        :observability_v2_llm_write,
        observability_llm_write,
        :backplane_telemetry
      )

      restore_env(
        :observability_v2_test_disabled,
        observability_test_disabled,
        :backplane_telemetry
      )
    end)

    %{endpoint_port: endpoint_port}
  end

  test "ordinary Responses traverses the listening API endpoint and submits once", %{
    endpoint_port: endpoint_port
  } do
    request_body =
      Jason.encode!(%{
        "model" => "endpoint-provider/endpoint-model",
        "input" => "hello"
      })

    response = post_over_socket(endpoint_port, "/v1/responses", request_body)

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ ~S("id":"resp_endpoint_1")

    captured = Agent.get(__MODULE__.Store, & &1)
    assert captured.submissions == 1
    assert captured.body["model"] == "endpoint-model"

    assert Enum.filter(captured.headers, &(elem(&1, 0) == "authorization")) ==
             [{"authorization", "Bearer sk-endpoint-provider"}]

    refute Enum.any?(captured.headers, fn {name, value} ->
             name == "x-api-key" or value == "Bearer endpoint-client-token"
           end)

    log = one_log!()
    assert log.operation == "responses"
    assert log.input_tokens == 11
    assert log.output_tokens == 7
    assert log.cached_tokens == 3
    assert log.reasoning_tokens == 2
    assert log.provider_request_id == "resp_endpoint_1"

    observation = get_in(log.metadata, ["protocol_observation"])
    assert observation["implementation"] =~ "OpenAIResponsesObserver"
    assert observation["observation_status"] == "complete"
    assert observation["protocol_terminal"] == "completed"
    assert observation["bytes_seen"] in 1..8_388_608
    assert length(observation["diagnostics"]) <= 32
  end

  test "semantic non-stream JSON over chunked transfer is observed exactly once", %{
    endpoint_port: endpoint_port
  } do
    request =
      Task.async(fn ->
        post_over_socket(endpoint_port, "/v1/responses", request_body("chunked-json"))
      end)

    assert_receive {:chunked_json_partial, upstream_pid}, 2_000
    assert endpoint_logs() == []
    send(upstream_pid, :release_chunked_json)

    response = Task.await(request, 5_000)
    {headers, body} = split_http_response(response)
    native_body = OpenAIUpstream.chunked_json_body()

    headers = String.downcase(headers)
    assert String.contains?(headers, "transfer-encoding: chunked")
    refute String.contains?(headers, "content-length:")
    assert decode_chunked_body(body) == native_body
    assert submission_count() == 1

    log = one_log!()
    assert log.input_tokens == 13
    assert log.output_tokens == 9
    assert log.cached_tokens == 4
    assert log.reasoning_tokens == 3
    assert log.provider_request_id == "resp_endpoint_chunked"

    observation = get_in(log.metadata, ["protocol_observation"])
    assert observation["implementation"] =~ "OpenAIResponsesObserver"
    assert observation["observation_status"] == "complete"
    assert observation["protocol_terminal"] == "completed"
    assert observation["bytes_seen"] == byte_size(native_body)
  end

  test "chunked non-stream overflow preserves bytes and records incomplete unknown usage", %{
    endpoint_port: endpoint_port
  } do
    response = post_over_socket(endpoint_port, "/v1/responses", request_body("chunked-overflow"))
    {headers, body} = split_http_response(response)
    native_body = OpenAIUpstream.oversized_chunked_json_body()

    headers = String.downcase(headers)
    assert String.contains?(headers, "transfer-encoding: chunked")
    refute String.contains?(headers, "content-length:")
    assert decode_chunked_body(body) == native_body
    assert submission_count() == 1

    log = one_log!()
    assert log.input_tokens == nil
    assert log.output_tokens == nil
    assert log.provider_request_id == nil

    observation = get_in(log.metadata, ["protocol_observation"])
    assert observation["observation_status"] == "incomplete"
    assert observation["protocol_terminal"] == "incomplete"
    assert observation["bytes_seen"] == byte_size(native_body)
    assert "observation_chunks_dropped" in observation["diagnostics"]
  end

  test "fragmented Responses SSE retains trailing usage through the listening endpoint", %{
    endpoint_port: endpoint_port
  } do
    response =
      post_over_socket(
        endpoint_port,
        "/v1/responses",
        request_body("stream", %{"stream" => true})
      )

    assert response =~ "HTTP/1.1 200 OK"
    assert submission_count() == 1

    log = one_log!()
    assert log.stream == true
    assert log.input_tokens == 6
    assert log.output_tokens == 3
    assert log.cached_tokens == 1
    assert log.reasoning_tokens == 1
    assert log.provider_request_id == "resp_endpoint_stream"
    assert get_in(log.metadata, ["protocol_observation", "terminal_count"]) == 1
  end

  test "native SSE forwards unknown events before the upstream completes and preserves bytes", %{
    endpoint_port: endpoint_port
  } do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        endpoint_port,
        [:binary, active: false, packet: :raw],
        2_000
      )

    try do
      :ok =
        :gen_tcp.send(
          socket,
          http_request("/v1/responses", request_body("early-stream", %{"stream" => true}))
        )

      assert_receive {:early_stream_partial, upstream_pid}, 2_000
      assert {:ok, early_bytes} = receive_until_bytes(socket, "provider.future", [], 2_000)
      assert early_bytes =~ "provider.future"
      refute early_bytes =~ "response.completed"

      send(upstream_pid, :release_early_stream)
      response = early_bytes <> receive_all(socket, [])
      {headers, body} = split_http_response(response)

      assert String.downcase(headers) =~ "transfer-encoding: chunked"
      assert decode_chunked_body(body) == OpenAIUpstream.early_stream_body()
    after
      :gen_tcp.close(socket)
    end

    assert submission_count() == 1
    log = one_log!()
    assert log.input_tokens == 4
    assert log.output_tokens == 2
    assert get_in(log.metadata, ["protocol_observation", "protocol_terminal"]) == "completed"
  end

  test "native errors remain observable without rewriting", %{endpoint_port: endpoint_port} do
    response = post_over_socket(endpoint_port, "/v1/responses", request_body("error"))

    assert response =~ "HTTP/1.1 400 Bad Request"
    assert String.downcase(response) =~ "x-upstream-request-id: upstream-error-123"
    assert response =~ "secret upstream detail"
    assert submission_count() == 1

    log = one_log!()
    assert log.outcome == "error"
    assert log.error_code == "endpoint_bad_request"
    assert log.error_reason == "invalid_request_error"
    refute log.error_reason =~ "secret"
  end

  test "malformed native JSON is unchanged and recorded incomplete", %{
    endpoint_port: endpoint_port
  } do
    response = post_over_socket(endpoint_port, "/v1/responses", request_body("malformed"))

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "{malformed"
    assert submission_count() == 1

    log = one_log!()
    assert log.input_tokens == nil
    assert log.output_tokens == nil
    assert get_in(log.metadata, ["protocol_observation", "observation_status"]) == "incomplete"
  end

  test "refusal remains native success with its business finish reason", %{
    endpoint_port: endpoint_port
  } do
    response = post_over_socket(endpoint_port, "/v1/responses", request_body("refusal"))

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "resp_endpoint_refusal"
    assert submission_count() == 1

    log = one_log!()
    assert log.outcome == "success"
    assert log.finish_reason == "refusal"
    assert get_in(log.metadata, ["protocol_observation", "protocol_terminal"]) == "completed"
  end

  test "output limit remains native success with an incomplete protocol terminal", %{
    endpoint_port: endpoint_port
  } do
    response = post_over_socket(endpoint_port, "/v1/responses", request_body("output-limit"))

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "resp_endpoint_limit"
    assert submission_count() == 1

    log = one_log!()
    assert log.outcome == "success"
    assert log.finish_reason == "max_output_tokens"
    assert get_in(log.metadata, ["protocol_observation", "protocol_terminal"]) == "incomplete"
  end

  test "truncated SSE is forwarded and recorded as an incomplete observation", %{
    endpoint_port: endpoint_port
  } do
    response =
      post_over_socket(
        endpoint_port,
        "/v1/responses",
        request_body("truncated", %{"stream" => true})
      )

    assert response =~ "HTTP/1.1 200 OK"
    assert response =~ "partial"
    assert submission_count() == 1

    log = one_log!()
    assert log.input_tokens == nil
    assert log.output_tokens == nil
    assert get_in(log.metadata, ["protocol_observation", "observation_status"]) == "incomplete"
    assert get_in(log.metadata, ["protocol_observation", "protocol_terminal"]) == "interrupted"
  end

  test "downstream disconnect submits and writes exactly once", %{endpoint_port: endpoint_port} do
    post_and_disconnect(
      endpoint_port,
      "/v1/responses",
      request_body("disconnect", %{"stream" => true})
    )

    assert submission_count() == 1

    log = one_log!()
    assert log.outcome == "cancelled"
    assert log.error_kind == "client_disconnect"
    assert log.error_code == "client_disconnect"
    assert get_in(log.metadata, ["protocol_observation", "observation_status"]) == "incomplete"
  end

  defp request_body(input, extra \\ %{}) do
    %{
      "model" => "endpoint-provider/endpoint-model",
      "input" => input
    }
    |> Map.merge(extra)
    |> Jason.encode!()
  end

  defp submission_count, do: Agent.get(__MODULE__.Store, & &1.submissions)

  defp one_log! do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_one_log!(deadline)
  end

  defp await_one_log!(deadline) do
    :sys.get_state(:llm_proxy)
    :ok = LogWriter.flush()

    logs = endpoint_logs()

    cond do
      length(logs) == 1 ->
        hd(logs)

      logs == [] and System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_one_log!(deadline)

      true ->
        flunk("expected exactly one durable endpoint log, got: #{length(logs)}")
    end
  end

  defp endpoint_logs do
    Backplane.Repo.all(
      from(l in ProxyRequest, where: l.requested_model == "endpoint-provider/endpoint-model")
    )
  end

  defp post_over_socket(port, path, body) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    try do
      :ok = :gen_tcp.send(socket, http_request(path, body))
      receive_all(socket, [])
    after
      :gen_tcp.close(socket)
    end
  end

  defp post_and_disconnect(port, path, body) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    :ok = :gen_tcp.send(socket, http_request(path, body))
    :ok = receive_until(socket, "first", [], 2_000)
    :ok = :inet.setopts(socket, linger: {true, 0})
    :gen_tcp.close(socket)
  end

  defp receive_until(socket, needle, chunks, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} ->
        chunks = [chunk | chunks]

        if chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.contains?(needle) do
          :ok
        else
          receive_until(socket, needle, chunks, timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_until_bytes(socket, needle, chunks, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} ->
        bytes = [chunks, chunk] |> IO.iodata_to_binary()

        if String.contains?(bytes, needle) do
          {:ok, bytes}
        else
          receive_until_bytes(socket, needle, bytes, timeout)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_request(path, body) do
    [
      "POST ",
      path,
      " HTTP/1.1\r\n",
      "host: 127.0.0.1\r\n",
      "authorization: Bearer endpoint-client-token\r\n",
      "x-api-key: inbound-key-must-not-leak\r\n",
      "content-type: application/json\r\n",
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n",
      body
    ]
  end

  defp receive_all(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> receive_all(socket, [chunk | chunks])
      {:error, :closed} -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp split_http_response(response) do
    case :binary.split(response, "\r\n\r\n") do
      [headers, body] -> {headers, body}
      _ -> flunk("expected an HTTP response with headers and body")
    end
  end

  defp decode_chunked_body(body), do: decode_chunked_body(body, [])

  defp decode_chunked_body(body, chunks) do
    [size_line, rest] = :binary.split(body, "\r\n")
    size = size_line |> :binary.split(";") |> hd() |> String.to_integer(16)

    if size == 0 do
      chunks |> Enum.reverse() |> IO.iodata_to_binary()
    else
      chunk = binary_part(rest, 0, size)
      <<"\r\n", remaining::binary>> = binary_part(rest, size, byte_size(rest) - size)
      decode_chunked_body(remaining, [chunk | chunks])
    end
  end

  defp stop_server(pid) do
    ThousandIsland.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp restore_env(key, value, app \\ :backplane)
  defp restore_env(key, nil, app), do: Application.delete_env(app, key)
  defp restore_env(key, value, app), do: Application.put_env(app, key, value)
end
