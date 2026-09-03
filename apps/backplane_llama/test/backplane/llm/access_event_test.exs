defmodule Backplane.LLM.AccessEventTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.AccessEvent
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
end
