defmodule Backplane.LLM.AccessEventTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{AccessEvent, Provider, UsageAccumulator}
  alias Backplane.Observability.Context

  @moduletag observability_v2: true

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
end
