defmodule Backplane.LLM.AccessEventTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{AccessEvent, Provider, UsageAccumulator}
  alias Backplane.Observability.Context

  @moduletag observability_v2: true

  test "failure logging returns normal results without finalizing the access event" do
    conn = conn(:post, "/v1/chat/completions", "{}")
    access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)

    assert AccessEvent.with_failure_logging(access, conn, fn -> {:ok, conn} end) == {:ok, conn}

    flush_logs!()
    assert access_logs(access) == []
  end

  test "failure logging persists one safe exception record and preserves the original stack" do
    secret = "private-exception-payload-sentinel"
    stack = [{__MODULE__, :proxy_callback, [secret], [file: ~c"access_event_test.exs", line: 1]}]

    for {exception, status, kind, code} <- [
          {RuntimeError.exception(secret), 500, "internal", "RuntimeError"},
          {Plug.BadRequestError.exception(message: secret), 400, "validation",
           "Plug.BadRequestError"},
          {Plug.TimeoutError.exception(message: secret), 408, "timeout", "Plug.TimeoutError"}
        ] do
      conn = conn(:post, "/v1/chat/completions", "{}")

      access =
        conn
        |> AccessEvent.start("chat_completions", :openai_chat_completions)
        |> AccessEvent.mark_stream()

      assert capture_failure(fn ->
               AccessEvent.with_failure_logging(access, conn, fn ->
                 :erlang.raise(:error, exception, stack)
               end)
             end) == {:error, exception, stack}

      assert_usage_acc_stopped(access)
      flush_logs!()
      assert [log] = access_logs(access)
      assert log.status == status
      assert log.outcome == "error"
      assert log.error_kind == kind
      assert log.error_code == code
      assert log.error_reason == "proxy_exception"
      refute inspect(log) =~ secret
    end
  end

  test "failure logging preserves exits and throws without retaining their reasons" do
    secret = "private-catch-payload-sentinel"
    stack = [{__MODULE__, :proxy_callback, [secret], [file: ~c"access_event_test.exs", line: 1]}]

    for {failure_kind, code} <- [exit: "proxy_exit", throw: "proxy_throw"] do
      conn = conn(:post, "/v1/chat/completions", "{}")
      access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)
      reason = {:private_reason, secret}

      assert capture_failure(fn ->
               AccessEvent.with_failure_logging(access, conn, fn ->
                 :erlang.raise(failure_kind, reason, stack)
               end)
             end) == {failure_kind, reason, stack}

      flush_logs!()
      assert [log] = access_logs(access)
      assert log.status == 500
      assert log.outcome == "error"
      assert log.error_kind == "internal"
      assert log.error_code == code
      assert log.error_reason == code
      refute inspect(log) =~ secret
    end
  end

  test "failure logging classifies wrapped errors using their connection and reraises the wrapper" do
    secret = "private-wrapped-payload-sentinel"
    conn = conn(:post, "/v1/chat/completions", "{}")
    access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)
    wrapped_conn = resp(conn, 400, "rendered error")
    stack = [{__MODULE__, :proxy_callback, [secret], [file: ~c"access_event_test.exs", line: 1]}]

    wrapper = %Plug.Conn.WrapperError{
      conn: wrapped_conn,
      kind: :error,
      reason: Plug.BadRequestError.exception(message: secret),
      stack: stack
    }

    assert capture_failure(fn ->
             AccessEvent.with_failure_logging(access, conn, fn ->
               :erlang.raise(:error, wrapper, stack)
             end)
           end) == {:error, wrapper, stack}

    flush_logs!()
    assert [log] = access_logs(access)
    assert log.status == 400
    assert log.response_bytes == byte_size("rendered error")
    assert log.error_kind == "validation"
    assert log.error_code == "Plug.BadRequestError"
    assert log.error_reason == "proxy_exception"
    refute inspect(log) =~ secret
  end

  test "failure logging retains only allowlisted adapter diagnostics for NotSentError" do
    for code <-
          ~w(system_memory_pressure safety_sample_unavailable memory_hard_limit timeout closed invalid_response_headers buffer_limit) do
      conn = conn(:post, "/v1/chat/completions", "{}")
      access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)
      exception = Plug.Conn.NotSentError.exception(message: ":" <> code)

      assert_raise Plug.Conn.NotSentError, exception.message, fn ->
        AccessEvent.with_failure_logging(access, conn, fn -> raise exception end)
      end

      flush_logs!()
      assert [log] = access_logs(access)
      assert log.status == 500
      assert log.error_kind == "internal"
      assert log.error_code == "Plug.Conn.NotSentError"
      assert log.error_reason == code
    end
  end

  test "failure logging suppresses unknown adapter messages and diagnostics from other exceptions" do
    secret = "private-adapter-reason-sentinel"

    for exception <- [
          Plug.Conn.NotSentError.exception(message: secret),
          Plug.Conn.NotSentError.exception(message: ":unknown_adapter_reason"),
          Plug.Conn.NotSentError.exception(message: ":system_memory_pressure " <> secret),
          RuntimeError.exception(":system_memory_pressure")
        ] do
      conn = conn(:post, "/v1/chat/completions", "{}")
      access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)

      assert_raise exception.__struct__, exception.message, fn ->
        AccessEvent.with_failure_logging(access, conn, fn -> raise exception end)
      end

      flush_logs!()
      assert [log] = access_logs(access)
      assert log.error_reason == "proxy_exception"
      refute inspect(log) =~ secret
      refute inspect(log) =~ "unknown_adapter_reason"
      refute inspect(log) =~ "system_memory_pressure"
    end
  end

  test "failure logging retains committed statuses independently of exception classification" do
    for wrapped? <- [false, true], state <- [:sent, :chunked, :file] do
      conn = conn(:post, "/v1/chat/completions", "{}")
      committed_conn = %{resp(conn, 200, "committed body") | state: state}
      access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)
      exception = Plug.TimeoutError.exception(message: "private-committed-payload-sentinel")

      {failure_conn, failure} =
        if wrapped? do
          {conn,
           %Plug.Conn.WrapperError{
             conn: committed_conn,
             kind: :error,
             reason: exception,
             stack: []
           }}
        else
          {committed_conn, exception}
        end

      assert_raise failure.__struct__, fn ->
        AccessEvent.with_failure_logging(access, failure_conn, fn -> raise failure end)
      end

      flush_logs!()
      assert [log] = access_logs(access)
      assert log.status == 200
      assert log.outcome == "error"
      assert log.error_kind == "timeout"
      assert log.error_code == "Plug.TimeoutError"
      assert log.response_bytes == byte_size("committed body")
      refute inspect(log) =~ "private-committed-payload-sentinel"
    end
  end

  test "failure logging does not treat a prepared response status as committed" do
    conn = conn(:post, "/v1/chat/completions", "{}") |> resp(200, "prepared body")
    access = AccessEvent.start(conn, "chat_completions", :openai_chat_completions)

    assert_raise RuntimeError, fn ->
      AccessEvent.with_failure_logging(access, conn, fn -> raise "private-prepared-sentinel" end)
    end

    flush_logs!()
    assert [log] = access_logs(access)
    assert log.status == 500
    assert log.error_kind == "internal"
    assert log.error_reason == "proxy_exception"
    refute inspect(log) =~ "private-prepared-sentinel"
  end

  test "failure logging preserves the disabled observability policy" do
    disable_observability_v2!()
    conn = conn(:post, "/v1/chat/completions", "{}")

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai_chat_completions)
      |> AccessEvent.mark_stream()

    exception = RuntimeError.exception("private-disabled-payload-sentinel")

    assert_raise RuntimeError, exception.message, fn ->
      AccessEvent.with_failure_logging(access, conn, fn -> raise exception end)
    end

    assert_usage_acc_stopped(access)
    flush_logs!()
    assert access_logs(access) == []
  end

  test "finalization failures preserve the original exception and stop usage accumulation" do
    conn = conn(:post, "/v1/chat/completions", "{}")

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai_chat_completions)
      |> AccessEvent.mark_stream()
      |> Map.put(:context, nil)

    exception = RuntimeError.exception("private-original-payload-sentinel")

    assert_raise RuntimeError, exception.message, fn ->
      AccessEvent.with_failure_logging(access, conn, fn -> raise exception end)
    end

    assert_usage_acc_stopped(access)
  end

  test "HTTP 200 explicit Responses failures persist as errors without overriding transport outcomes" do
    for {outcome, opts, expected, kind, code} <- [
          {:success, [], "error", "upstream_error", "rate_limit_exceeded"},
          {:error, [error_kind: "timeout", error_code: "upstream_timeout"], "error", "timeout",
           "upstream_timeout"},
          {:cancelled, [], "cancelled", "client_disconnect", "client_disconnect"}
        ] do
      model = "failed-response-#{outcome}"
      conn = conn(:post, "/v1/responses", "{}") |> send_resp(200, "")

      access =
        conn
        |> AccessEvent.start("responses", :openai_responses)
        |> AccessEvent.put_requested_model(model)
        |> AccessEvent.put_resolution(%Provider{preset_key: "openai"}, "gpt", nil)
        |> AccessEvent.mark_stream()

      AccessEvent.scan_stream_chunk(
        access,
        ~S(data: {"type":"response.failed","response":{"status":"failed","error":{"code":"rate_limit_exceeded","type":"server_error","message":"private payload"}}}) <>
          "\n\n"
      )

      :ok = AccessEvent.finalize(access, conn, outcome, opts)
      flush_logs!()
      log = log_for_model(model)
      assert log.status == 200
      assert log.outcome == expected
      assert log.error_kind == kind
      assert log.error_code == code
      refute inspect(log) =~ "private payload"
    end
  end

  test "HTTP 200 incomplete observation is not reclassified as an upstream failure" do
    conn = conn(:post, "/v1/responses", "{}") |> send_resp(200, "")

    access =
      conn
      |> AccessEvent.start("responses", :openai_responses)
      |> AccessEvent.put_requested_model("unknown-response")
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai"}, "gpt", nil)
      |> AccessEvent.mark_stream()

    AccessEvent.scan_stream_chunk(access, "data: malformed\n\n")
    :ok = AccessEvent.finalize(access, conn, :success)
    flush_logs!()
    assert %{status: 200, outcome: "success", error_kind: nil} = log_for_model("unknown-response")
  end

  test "HTTP 200 native error events persist bounded upstream error metadata" do
    conn = conn(:post, "/v1/responses", "{}") |> send_resp(200, "")

    access =
      conn
      |> AccessEvent.start("responses", :openai_responses)
      |> AccessEvent.put_requested_model("native-error-response")
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai"}, "gpt", nil)
      |> AccessEvent.mark_stream()

    AccessEvent.scan_stream_chunk(
      access,
      ~S(data: {"type":"error","code":"server_error","message":"private upstream message"}) <>
        "\n\n"
    )

    :ok = AccessEvent.finalize(access, conn, :success)
    flush_logs!()

    log = log_for_model("native-error-response")
    assert log.status == 200
    assert log.outcome == "error"
    assert log.error_kind == "upstream_error"
    assert log.error_code == "server_error"
    refute inspect(log) =~ "private upstream message"
  end

  test "finalize emits a durable access record" do
    context = Context.root(request_id: "req-access-event", trace_id: String.duplicate("b", 32))

    conn =
      conn(:post, "/v1/chat/completions", "{}")
      |> Context.put(context)
      |> send_resp(200, ~s({"usage":{"prompt_tokens":1,"completion_tokens":2}}))

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai_chat_completions)
      |> AccessEvent.put_requested_model("demo/model")
      |> AccessEvent.prepare_response_observation()

    AccessEvent.scan_stream_chunk(access, conn.resp_body)

    :ok = AccessEvent.finalize(access, conn, :success, status: 200)
    flush_logs!()

    log = log_for_model("demo/model")
    assert log.outcome == "success"
    assert log.operation == "chat_completions"
    assert log.request_id == "req-access-event"
    assert log.input_tokens == 1
    assert log.output_tokens == 2
    assert log.raw_request == nil
  end

  test "finalize persists the authenticated resource client ID" do
    client_id = Ecto.UUID.generate()

    conn =
      conn(:post, "/v1/chat/completions", "{}")
      |> assign(:resource_auth, %{client_id: client_id})
      |> send_resp(200, ~s({"usage":{"prompt_tokens":1,"completion_tokens":2}}))

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai_chat_completions)
      |> AccessEvent.put_requested_model("client-owned-model")
      |> AccessEvent.prepare_response_observation()

    AccessEvent.scan_stream_chunk(access, conn.resp_body)

    :ok = AccessEvent.finalize(access, conn, :success, status: 200)
    flush_logs!()

    assert %{client_id: ^client_id} = log_for_model("client-owned-model")
  end

  test "compact streaming requests retain the compact legacy protocol" do
    conn = conn(:post, "/v1/providers/codex/responses/compact", "{}")

    access =
      conn
      |> AccessEvent.start("compact", :openai)
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai-codex"}, "codex", nil)
      |> AccessEvent.mark_stream()

    assert %{protocol: :compact} = Agent.get(access.usage_acc, & &1)
    UsageAccumulator.stop(access.usage_acc)
  end

  test "Codex Responses streaming persists usage from a fragmented terminal event" do
    conn = conn(:post, "/v1/responses", "{}") |> send_resp(200, "")

    access =
      conn
      |> AccessEvent.start("responses", :openai_responses)
      |> AccessEvent.put_requested_model("codex-stream-usage")
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai-codex"}, "gpt", nil)
      |> AccessEvent.mark_stream()

    event =
      ~S(data: {"type":"response.completed","response":{"id":"resp_codex","status":"completed","usage":{"input_tokens":123,"output_tokens":45,"input_tokens_details":{"cached_tokens":67}}}}) <>
        "\n\n"

    for <<chunk::binary-size(1) <- event>>, do: AccessEvent.scan_stream_chunk(access, chunk)

    :ok = AccessEvent.finalize(access, conn, :success)
    flush_logs!()

    log = log_for_model("codex-stream-usage")
    assert log.input_tokens == 123
    assert log.cached_tokens == 67
    assert log.output_tokens == 45
    assert log.total_tokens == 168
    assert log.provider_request_id == "resp_codex"
    assert log.metadata["protocol_observation"]["usage_status"] == "complete"
  end

  test "Codex Responses nonstreaming persists usage from the response body" do
    body =
      ~S({"id":"resp_codex_body","status":"completed","usage":{"input_tokens":123,"output_tokens":45,"input_tokens_details":{"cached_tokens":67}}})

    conn = conn(:post, "/v1/responses", "{}") |> send_resp(200, body)

    access =
      conn
      |> AccessEvent.start("responses", :openai_responses)
      |> AccessEvent.put_requested_model("codex-body-usage")
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai-codex"}, "gpt", nil)
      |> AccessEvent.prepare_response_observation()

    AccessEvent.scan_stream_chunk(access, body)
    :ok = AccessEvent.finalize(access, conn, :success)
    flush_logs!()

    log = log_for_model("codex-body-usage")
    assert log.input_tokens == 123
    assert log.cached_tokens == 67
    assert log.output_tokens == 45
    assert log.total_tokens == 168
    assert log.provider_request_id == "resp_codex_body"
    assert log.metadata["protocol_observation"]["usage_status"] == "complete"
    assert log.ttft_ms == nil
    assert log.stream_duration_ms == nil
    refute get_in(log.metadata, ["timing", "basis"])
  end

  test "ordinary Responses streaming requests retain the shared observer" do
    conn = conn(:post, "/v1/responses", "{}")

    access =
      conn
      |> AccessEvent.start("responses", :openai_responses)
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai"}, "gpt", nil)
      |> AccessEvent.mark_stream()

    assert %{protocol: :openai_responses} = Agent.get(access.usage_acc, & &1)
    Backplane.LLM.UsageAccumulator.stop(access.usage_acc)
  end

  test "stream content timing is persisted relative to request start" do
    conn = conn(:post, "/v1/chat/completions", "{}") |> send_resp(200, "")

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai_chat_completions)
      |> AccessEvent.put_requested_model("request-content-timing")

    # Simulate time spent routing before the upstream stream starts.
    access = %{access | started_at_mono: access.started_at_mono - 500}
    access = AccessEvent.mark_stream(access)

    AccessEvent.scan_stream_chunk(access, ": heartbeat\n\n")

    AccessEvent.scan_stream_chunk(
      access,
      ~S(data: {"choices":[{"delta":{"content":"hi"}}]}) <> "\n\n"
    )

    AccessEvent.scan_stream_chunk(
      access,
      ~S(data: {"usage":{"prompt_tokens":3,"completion_tokens":5}}) <> "\n\n"
    )

    :ok = AccessEvent.finalize(access, conn, :success)
    flush_logs!()

    log = log_for_model("request-content-timing")
    assert log.ttft_ms >= 500
    assert log.ttft_ms <= log.duration_ms
    assert is_integer(log.stream_duration_ms)
    assert log.stream_duration_ms >= 0
    assert log.metadata["timing"]["basis"] == "first_content"
    assert log.output_tokens == 5
  end

  test "usage-only stream does not fabricate first-token timing" do
    conn = conn(:post, "/v1/chat/completions", "{}") |> send_resp(200, "")

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai_chat_completions)
      |> AccessEvent.put_requested_model("usage-only-timing")
      |> AccessEvent.mark_stream()

    AccessEvent.scan_stream_chunk(
      access,
      ~S(data: {"usage":{"prompt_tokens":3,"completion_tokens":0}}) <> "\n\n"
    )

    :ok = AccessEvent.finalize(access, conn, :success)
    flush_logs!()

    log = log_for_model("usage-only-timing")
    assert log.ttft_ms == nil
    assert log.stream_duration_ms == nil
    assert log.output_tokens == 0
  end

  defp access_logs(access) do
    Backplane.Repo.all(
      from(log in Backplane.LLM.ProxyRequest, where: log.event_id == ^access.event_id)
    )
  end

  defp capture_failure(fun) do
    fun.()
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

  defp assert_usage_acc_stopped(%{usage_acc: pid}) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
  end
end
