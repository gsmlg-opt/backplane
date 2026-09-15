defmodule Backplane.LLM.AccessEventTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{AccessEvent, Provider, UsageAccumulator}
  alias Backplane.Observability.Context

  @moduletag observability_v2: true

  test "finalize emits a durable access record" do
    context = Context.root(request_id: "req-access-event", trace_id: String.duplicate("b", 32))

    conn =
      conn(:post, "/v1/chat/completions", "{}")
      |> Context.put(context)
      |> send_resp(200, ~s({"usage":{"prompt_tokens":1,"completion_tokens":2}}))

    access =
      conn
      |> AccessEvent.start("chat_completions", :openai)
      |> AccessEvent.put_requested_model("demo/model")

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
      |> AccessEvent.start("responses", :openai)
      |> AccessEvent.put_resolution(%Provider{preset_key: "openai"}, "gpt", nil)
      |> AccessEvent.mark_stream()

    assert %{protocol: :openai_responses} = Agent.get(access.usage_acc, & &1)
    Backplane.LLM.UsageAccumulator.stop(access.usage_acc)
  end
end
