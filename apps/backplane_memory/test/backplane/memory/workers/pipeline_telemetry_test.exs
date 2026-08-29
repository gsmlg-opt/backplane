defmodule Backplane.Memory.Workers.PipelineTelemetryTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Workers.{
    AccessWritebackWorker,
    EpisodicWorker,
    EvictionWorker,
    FallbackSweepWorker,
    LeaseCleanupWorker,
    ProceduralWorker
  }

  @event [:backplane, :memory, :pipeline]
  @metadata_keys ~w(client_id error_class host_id integration namespace project scope session_id source_type stage status)a

  setup do
    handler = "memory-worker-pipeline-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    setting = :ets.lookup(:backplane_settings, "memory.llm_model")
    :ets.delete(:backplane_settings, "memory.llm_model")

    on_exit(fn ->
      :telemetry.detach(handler)
      if setting != [], do: :ets.insert(:backplane_settings, setting)
    end)

    :ok
  end

  test "previously uncovered workers emit one bounded content-free pipeline event" do
    secret = "must-not-escape-pipeline-telemetry"

    jobs = [
      {AccessWritebackWorker, "access.writeback", %{"content" => secret}},
      {EpisodicWorker, "episodic", %{"content" => secret}},
      {EvictionWorker, "eviction", %{"batch_size" => 1, "content" => secret}},
      {FallbackSweepWorker, "fallback.sweep", %{"content" => secret}},
      {LeaseCleanupWorker, "lease.cleanup", %{"content" => secret}},
      {ProceduralWorker, "procedural", %{"content" => secret}}
    ]

    Enum.each(jobs, fn {worker, stage, args} ->
      _result = worker.perform(%Oban.Job{args: args})

      assert_receive {@event, %{count: 1, duration_us: duration_us}, metadata}
      assert duration_us >= 0
      assert metadata.stage == stage
      assert metadata.status in ~w(ok cancelled error skipped retry dead_letter)
      assert Map.keys(metadata) |> Enum.sort() == Enum.sort(@metadata_keys)
      refute inspect(metadata) =~ secret
      refute_receive {@event, _, _}, 10
    end)
  end
end
