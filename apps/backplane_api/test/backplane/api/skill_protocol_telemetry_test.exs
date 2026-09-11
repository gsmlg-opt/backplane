defmodule Backplane.Api.SkillProtocolTelemetryTest do
  use Backplane.Api.ConnCase, async: false

  @event [:backplane, :skill_protocol, :operation]

  setup do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn event, measurements, metadata, owner ->
          send(owner, {:skill_protocol_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "v1 reads emit bounded success and error events without query bodies or paths", %{
    conn: conn
  } do
    private_query = "/private/consumer/skill-body"

    assert conn
           |> get("/skill-protocol/v1/catalog?q=#{URI.encode_www_form(private_query)}")
           |> json_response(200)

    assert_receive {:skill_protocol_telemetry, @event,
                    %{duration_ms: duration, request_bytes: 0, response_bytes: response_bytes},
                    %{
                      phase: :server,
                      operation: :catalog,
                      outcome: :ok,
                      source_id: "backplane",
                      http_status: 200
                    } = success_metadata}

    assert duration >= 0
    assert response_bytes > 0

    assert conn
           |> recycle()
           |> get("/skill-protocol/v1/catalog?limit=invalid")
           |> json_response(400)

    assert_receive {:skill_protocol_telemetry, @event, _measurements,
                    %{
                      phase: :server,
                      operation: :catalog,
                      outcome: :error,
                      error_code: :invalid_request,
                      http_status: 400
                    } = error_metadata}

    exposed = inspect({success_metadata, error_metadata})
    refute exposed =~ private_query
    refute exposed =~ "authorization"
  end
end
