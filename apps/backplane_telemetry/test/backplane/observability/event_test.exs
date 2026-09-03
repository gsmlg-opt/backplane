defmodule Backplane.Observability.EventTest do
  use ExUnit.Case, async: true

  alias Backplane.Observability.{Context, Event}

  setup do
    handler_id = BackplaneTelemetry.TelemetryCapture.attach(self(), [:backplane, :llm_proxy, :request, :stop])
    on_exit(fn -> BackplaneTelemetry.TelemetryCapture.detach(handler_id) end)
    :ok
  end

  test "builds and emits a validated terminal event" do
    context = Context.root(request_id: "req-1", trace_id: "trace-1", span_id: "span-1")

    :ok =
      Event.emit_stop(:llm_proxy, "request", context,
        measurements: %{duration_ms: 12},
        attributes: %{provider: "anthropic", outcome: "success"}
      )

    assert_receive {:telemetry_capture, [:backplane, :llm_proxy, :request, :stop], measurements,
                    metadata}
    assert measurements.duration_ms == 12
    assert metadata.operation == "request"
    assert metadata.phase == "stop"
    assert get_in(metadata, [:context, "trace_id"]) == "trace-1" ||
             get_in(metadata, [:context, :trace_id]) == "trace-1"
    assert get_in(metadata, [:attributes, "provider"]) == "anthropic"
  end

  test "rejects unknown domains" do
    context = Context.root()

    assert {:error, {:invalid_domain, :unknown_domain}} =
             Event.new_root(:unknown_domain, "request", context)
             |> Event.validate()
  end
end
