defmodule Backplane.SkillProtocol.TelemetryTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.{Client, Error, Telemetry}

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

  test "client emits bounded success and stable error events without secrets or endpoints" do
    success =
      client(fn _request ->
        {:ok,
         %{
           status: 200,
           headers: %{},
           body: JSON.encode!(%{"protocol_version" => "1", "data" => [], "next_cursor" => nil})
         }}
      end)

    assert {:ok, %{data: [], next_cursor: nil}} = Client.catalog(success)

    assert_receive {:skill_protocol_telemetry, @event,
                    %{duration_ms: duration, request_bytes: 0, response_bytes: response_bytes},
                    %{
                      phase: :client,
                      operation: :catalog,
                      outcome: :ok,
                      source_id: "source-a"
                    } = success_metadata}

    assert duration >= 0
    assert response_bytes > 0
    refute Map.has_key?(success_metadata, :error_code)

    denied =
      client(fn _request ->
        {:ok,
         %{
           status: 403,
           headers: %{},
           body:
             JSON.encode!(%{
               "protocol_version" => "1",
               "error" => %{
                 "code" => "forbidden",
                 "message" => "denied",
                 "retryable" => false,
                 "context" => %{}
               }
             })
         }}
      end)

    assert {:error, %Error{code: :forbidden}} = Client.resolve(denied, "opaque/id", "r1")

    assert_receive {:skill_protocol_telemetry, @event, error_measurements,
                    %{
                      phase: :client,
                      operation: :resolve,
                      outcome: :error,
                      error_code: :forbidden,
                      skill_id: "opaque/id",
                      revision: "r1"
                    } = error_metadata}

    exposed = inspect({success_metadata, error_metadata, error_measurements})
    refute exposed =~ "telemetry-secret"
    refute exposed =~ "backplane.example"
    refute exposed =~ "/private/consumer/cache"
  end

  test "event contract drops unrecognized metadata and clamps byte counts" do
    started_at = Telemetry.start()

    assert :ok =
             Telemetry.emit(:cache, :install, :ok, started_at,
               metadata: %{
                 cache_outcome: :hit,
                 credential: "telemetry-secret",
                 path: "/private/consumer/cache"
               },
               measurements: %{artifact_bytes: -1, prepared_bytes: 99, body: 100}
             )

    assert_receive {:skill_protocol_telemetry, @event,
                    %{artifact_bytes: 0, duration_ms: duration, prepared_bytes: 99},
                    %{
                      phase: :cache,
                      operation: :install,
                      outcome: :ok,
                      cache_outcome: :hit
                    } = metadata}

    assert duration >= 0
    refute Map.has_key?(metadata, :credential)
    refute Map.has_key?(metadata, :path)
  end

  defp client(transport) do
    Client.new!(
      endpoint: "https://backplane.example",
      source_id: "source-a",
      access_context_id: "private-context",
      credential_supplier: fn -> "telemetry-secret" end,
      max_attempts: 1,
      transport: transport
    )
  end
end
