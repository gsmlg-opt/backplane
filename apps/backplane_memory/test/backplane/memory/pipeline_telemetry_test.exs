defmodule Backplane.Memory.PipelineTelemetryTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.PipelineTelemetry
  alias Backplane.Memory.Workers.CrystalWorker

  test "emits uniform content-free success and error measurements" do
    handler = "pipeline-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :memory, :pipeline],
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    metadata = %{
      "host_id" => "host-1",
      "client_id" => "client-1",
      "scope" => "private",
      "namespace" => "private",
      "session_id" => "session-1",
      "content" => "must not escape"
    }

    assert {:ok, :done} =
             PipelineTelemetry.span("lesson.candidate", metadata, fn -> {:ok, :done} end)

    assert_receive {[:backplane, :memory, :pipeline], %{count: 1, duration_us: duration}, success}

    assert duration >= 0
    assert success.stage == "lesson.candidate"
    assert success.status == "ok"
    assert success.error_class == nil
    assert success.host_id == "host-1"
    refute inspect(success) =~ "must not escape"

    assert {:error, :provider_unavailable} =
             PipelineTelemetry.span("summary", metadata, fn ->
               {:error, :provider_unavailable}
             end)

    assert_receive {[:backplane, :memory, :pipeline], %{count: 1}, failed}
    assert failed.status == "error"
    assert failed.error_class == "provider_unavailable"
  end

  test "crystal jobs retain their worker result and emit the uniform pipeline event" do
    handler = "crystal-pipeline-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:backplane, :memory, :pipeline],
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:cancel, :invalid_arguments} = CrystalWorker.perform(%Oban.Job{args: %{}})

    assert_receive {[:backplane, :memory, :pipeline], %{count: 1, duration_us: duration}, metadata}
    assert duration >= 0
    assert metadata.stage == "crystal"
    assert metadata.status == "cancelled"
    assert metadata.error_class == "invalid_arguments"
  end
end
