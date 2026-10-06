defmodule Backplane.Audio.AccessLifecycleTest do
  use Backplane.LLM.ObservabilityCase, async: false

  import Plug.Test

  alias Backplane.Audio.AccessLifecycle
  alias Backplane.Observability.{Buffer, Context}

  @moduletag observability_v2: true
  @stop_event [:backplane, :llm_proxy, :request, :stop]

  setup do
    id = "audio-access-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        @stop_event,
        fn _, measurements, metadata, _ ->
          send(parent, {:audio_stop, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  test "success persists safe units and no payload, connection, or fabricated tokens" do
    request_id = "audio-success-#{System.unique_integer([:positive])}"
    conn = audio_conn(request_id)
    {:ok, lifecycle} = AccessLifecycle.start(self(), conn, "audio.speech")

    assert :ok =
             AccessLifecycle.update(lifecycle, %{
               requested_model: "speech-2.8-turbo",
               resolved_model: "speech-2.8-turbo",
               credential_ref: "minimax-key-1",
               input_characters: 11,
               usage_characters: 15,
               sample_rate: 24_000,
               channels: 1,
               input_format: :wav,
               audio_seconds: 1.25,
               request_bytes: 200,
               output_format: "mp3",
               strategy: "native",
               input: "private speech text",
               transcript: "private transcript",
               raw_body: "private raw body",
               temp_path: "/tmp/private-file",
               access_token: "private key"
             })

    state = :sys.get_state(lifecycle)
    assert state.fields.input_format == "wav"
    assert state.fields.output_format == "mp3"
    assert state.fields.strategy == "native"
    assert state.fields.sample_rate == 24_000
    assert state.fields.channels == 1
    assert state.fields.usage_characters == 15
    refute inspect(state) =~ "private"

    assert :ok = AccessLifecycle.dispatched(lifecycle)
    assert :ok = AccessLifecycle.delivered(lifecycle, 123)
    assert :ok = AccessLifecycle.finish(lifecycle, :success, 200)
    assert {:error, :closed} = AccessLifecycle.finish(lifecycle, :error, 500)

    {measurements, metadata} = stop_event()
    assert measurements.duration_ms >= 0
    attrs = metadata.attributes
    assert attrs["operation"] == "audio.speech"
    assert attrs["request_bytes"] == 200
    assert attrs["response_bytes"] == 123
    assert attrs["input_tokens"] == nil
    assert attrs["metadata"]["audio"]["input_characters"] == 11
    assert attrs["metadata"]["audio"]["audio_seconds"] == 1.25
    assert attrs["metadata"]["audio"]["usage_characters"] == 15
    assert attrs["metadata"]["audio"]["sample_rate"] == 24_000
    assert attrs["metadata"]["audio"]["channels"] == 1
    assert attrs["metadata"]["audio"]["input_format"] == "wav"
    assert attrs["metadata"]["audio"]["output_format"] == "mp3"
    assert attrs["metadata"]["audio"]["strategy"] == "native"
    assert attrs["metadata"]["audio"]["provider_dispatched"] == "true"
    assert attrs["metadata"]["audio"]["paid_uncertain"] == "false"
    refute_receive {:audio_stop, _, _}, 50

    flush_logs!()
    log = log_for_request(request_id)
    assert log.operation == "audio.speech"
    assert log.input_tokens == nil
    assert log.output_tokens == nil
    assert log.metadata["audio"]["input_characters"] == 11
    assert log.metadata["audio"]["audio_seconds"] == 1.25
    assert log.metadata["audio"]["credential_ref"] == "minimax-key-1"
    assert log.metadata["audio"] == attrs["metadata"]["audio"]
    refute inspect(metadata) =~ "private"
    refute inspect(log) =~ "private"
  end

  test "enum strings and atoms normalize identically through storage" do
    for {input_format, output_format, strategy} <- [
          {"wav", "mp3", "native"},
          {:wav, :mp3, :native}
        ] do
      request_id = "audio-enums-#{System.unique_integer([:positive])}"
      {:ok, lifecycle} = AccessLifecycle.start(self(), audio_conn(request_id), "audio.speech")

      assert :ok =
               AccessLifecycle.update(lifecycle, %{
                 input_format: input_format,
                 output_format: output_format,
                 strategy: strategy,
                 sample_rate: 192_000,
                 channels: 8,
                 usage_characters: 0
               })

      expected = %{
        input_format: "wav",
        output_format: "mp3",
        strategy: "native",
        sample_rate: 192_000,
        channels: 8,
        usage_characters: 0
      }

      assert :sys.get_state(lifecycle).fields == expected
      assert :ok = AccessLifecycle.finish(lifecycle, :success, 200)
      {_, event} = stop_event()
      audio = event.attributes["metadata"]["audio"]
      for {key, value} <- expected, do: assert(audio[to_string(key)] == value)
      flush_logs!()
      assert log_for_request(request_id).metadata["audio"] == audio
    end
  end

  test "invalid media and usage values never enter state, telemetry, or storage" do
    for {sample_rate, channels, usage_characters, format, strategy} <- [
          {nil, nil, nil, nil, nil},
          {0, 0, -1, "unknown", "unknown"},
          {192_001, 9, 1_000_000_001, :unknown, :unknown},
          {24_000.0, 1.0, 1.5, 123, 123},
          {"24000", "1", "15", %{}, []}
        ] do
      request_id = "audio-invalid-#{System.unique_integer([:positive])}"

      {:ok, lifecycle} =
        AccessLifecycle.start(self(), audio_conn(request_id), "audio.transcriptions")

      fields = %{
        sample_rate: sample_rate,
        channels: channels,
        usage_characters: usage_characters,
        input_format: format,
        output_format: format,
        strategy: strategy,
        provider_dispatched: true,
        paid_uncertain: true
      }

      assert :ok = AccessLifecycle.update(lifecycle, fields)
      assert :sys.get_state(lifecycle).fields == %{}
      assert :ok = AccessLifecycle.finish(lifecycle, :error, 502, "upstream_error", fields)
      {_, event} = stop_event()
      audio = event.attributes["metadata"]["audio"]
      assert audio == %{"provider_dispatched" => "false", "paid_uncertain" => "false"}
      flush_logs!()
      log = log_for_request(request_id)
      assert log.metadata["audio"] == audio
      assert log.input_tokens == nil
      assert log.output_tokens == nil
    end
  end

  test "configured deadlines beyond the default are retained within the timer bound" do
    for deadline_ms <- [600_001, 4_294_967_295] do
      {:ok, lifecycle} =
        AccessLifecycle.start(self(), audio_conn("long-deadline"), "audio.speech",
          deadline_ms: deadline_ms
        )

      remaining = Process.read_timer(:sys.get_state(lifecycle).timer)
      assert remaining > deadline_ms - 1_000
      assert remaining <= deadline_ms
      assert :ok = AccessLifecycle.finish(lifecycle, :success, 200)
      stop_event()
    end

    for invalid <- [0, -1, 4_294_967_296, 1.5, "600000", nil] do
      assert {:error, :invalid_deadline} =
               AccessLifecycle.start(self(), audio_conn("invalid-deadline"), "audio.speech",
                 deadline_ms: invalid
               )
    end

    refute_receive {:audio_stop, _, _}, 50
  end

  test "owner death before and after dispatch emits one conservative terminal event" do
    for dispatched? <- [false, true] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, lifecycle} =
        AccessLifecycle.start(owner, audio_conn("owner-#{dispatched?}"), "audio.transcriptions")

      if dispatched?, do: assert(:ok = AccessLifecycle.dispatched(lifecycle))
      Process.exit(owner, :kill)

      {_measurements, metadata} = stop_event()
      assert metadata.attributes["outcome"] == "cancelled"
      assert metadata.attributes["error_code"] == "owner_down"
      assert metadata.attributes["metadata"]["audio"]["paid_uncertain"] == to_string(dispatched?)
      assert {:error, :closed} = AccessLifecycle.update(lifecycle, %{request_bytes: 9})
    end

    refute_receive {:audio_stop, _, _}, 50
  end

  test "timeout, late failure, shutdown, and competing finalizers each emit once" do
    {:ok, timeout} =
      AccessLifecycle.start(self(), audio_conn("deadline"), "audio.speech", deadline_ms: 20)

    assert :ok = AccessLifecycle.dispatched(timeout)
    {_measurements, event} = stop_event()
    assert event.attributes["outcome"] == "timeout"
    assert event.attributes["metadata"]["audio"]["paid_uncertain"] == "true"

    {:ok, late} = AccessLifecycle.start(self(), audio_conn("late"), "audio.speech")
    assert :ok = AccessLifecycle.delivered(late, 100)
    assert :ok = AccessLifecycle.dispatched(late)
    assert :ok = AccessLifecycle.finish(late, :error, 200, "late_stream_failure")
    {_measurements, event} = stop_event()
    assert event.attributes["outcome"] == "error"
    assert event.attributes["response_bytes"] == 100
    assert event.attributes["metadata"]["audio"]["paid_uncertain"] == "true"

    {:ok, shutdown} = AccessLifecycle.start(self(), audio_conn("shutdown"), "audio.speech")
    assert :ok = DynamicSupervisor.terminate_child(AccessLifecycle.Supervisor, shutdown)
    {_measurements, event} = stop_event()
    assert event.attributes["error_code"] == "lifecycle_shutdown"

    {:ok, race} = AccessLifecycle.start(self(), audio_conn("race"), "audio.transcriptions")

    results =
      1..8
      |> Task.async_stream(fn _ -> AccessLifecycle.finish(race, :success, 200) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    {_measurements, event} = stop_event()
    assert event.attributes["outcome"] == "success"
    refute_receive {:audio_stop, _, _}, 50
  end

  test "malicious metadata is dropped and audio persistence respects the live toggle" do
    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, true)

    request_id = "audio-disabled-#{System.unique_integer([:positive])}"

    {:ok, lifecycle} =
      AccessLifecycle.start(self(), audio_conn(request_id), "audio.transcriptions")

    assert :ok =
             AccessLifecycle.update(lifecycle, %{
               requested_model: "Bearer secret",
               provider_request_id: "/tmp/private",
               credential_ref: "private value with spaces",
               transcript: "private transcript",
               input_characters: -1,
               upstream_bytes: 42,
               audio_seconds: 0.5
             })

    assert :ok = AccessLifecycle.finish(lifecycle, :error, 502, "private error text")
    {_measurements, event} = stop_event()
    assert event.attributes["requested_model"] == nil
    assert event.attributes["provider_request_id"] == nil
    assert event.attributes["error_code"] == nil
    assert event.attributes["metadata"]["audio"]["upstream_bytes"] == 42
    assert event.attributes["metadata"]["audio"]["input_characters"] == nil
    refute inspect(event) =~ "private"

    assert Buffer.health(:llm_proxy).queued == 0
    flush_logs!()
    assert log_for_request(request_id) == nil
    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, false)
  end

  test "session reports real probe, conversion, duration, and output geometry" do
    alias Backplane.Audio.Media.Session
    policy = Backplane.Audio.Config.policy()

    {:ok, observer} =
      AccessLifecycle.start(self(), audio_conn("session-geometry"), "audio.speech")

    {:ok, session} = Session.start(self(), policy)
    :ok = Session.observe(session, observer)
    {:ok, path} = Session.input_path(session)
    fixture = Application.app_dir(:backplane_llama, "priv/audio/readiness/flac-flac.flac")
    :ok = Session.reserve_input(session, File.stat!(fixture).size)
    File.cp!(fixture, path)

    try do
      assert {:ok, _artifact} =
               Session.prepare(session, :speech, path, "wav", %{source_format: "flac"})

      fields = :sys.get_state(observer).fields
      assert fields.probe_ms >= 0
      assert fields.conversion_ms >= 0
      assert fields.audio_seconds > 0
      assert fields.input_format == "flac"
      assert fields.output_format == "wav"
      assert fields.strategy == "transcode"
      assert fields.sample_rate == 24000
      assert fields.channels == 1
      :ok = AccessLifecycle.finish(observer, :success, 200)
      stop_event()
    after
      Session.release(session)
    end
  end

  test "queued success and owner death cannot win after the absolute deadline" do
    for terminal <- [:success, :owner_down] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      deadline = System.monotonic_time(:millisecond) + 100

      {:ok, observer} =
        AccessLifecycle.start(owner, audio_conn("deadline-race"), "audio.speech",
          deadline_at_ms: deadline
        )

      :ok = :sys.suspend(observer)

      if terminal == :success do
        send(observer, {:"$gen_call", {self(), make_ref()}, {:finish, :success, 200, nil, %{}}})
      else
        Process.exit(owner, :kill)
      end

      Process.sleep(120)
      :ok = :sys.resume(observer)
      {_, event} = stop_event()
      assert event.attributes["outcome"] == "timeout"
      assert event.attributes["error_code"] == "audio_deadline"
      refute_receive {:audio_stop, _, _}, 30
      if Process.alive?(owner), do: send(owner, :stop)
    end
  end

  test "closed observer prevents MiniMax from opening a provider connection" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, observer} = AccessLifecycle.start(self(), audio_conn("closed-dispatch"), "audio.speech")
    :ok = AccessLifecycle.finish(observer, :cancelled, nil)
    stop_event()
    request = %{observer: observer, input: "private input", speed: 1.0}

    execution = %{
      resolution: %{model: "speech", api_origin: "http://127.0.0.1:#{port}"},
      voice: "voice",
      secret: "private key",
      deadline: System.monotonic_time(:millisecond) + 1000,
      policy: Backplane.Audio.Config.policy(),
      native_format: "mp3"
    }

    assert {:error, %Backplane.Audio.Error{status: 504}, _, _} =
             Backplane.Audio.Adapters.MiniMax.speech(
               request,
               execution,
               false,
               fn _, acc -> {:ok, acc} end,
               nil
             )

    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
    refute_receive {:audio_stop, _, _}, 30
  end

  test "validated SSE metadata survives later failure in the same fragment" do
    {:ok, observer} = AccessLifecycle.start(self(), audio_conn("stream-metadata"), "audio.speech")
    decoder = Backplane.Audio.Stream.new(Backplane.Audio.Config.policy(), observer)

    event =
      Jason.encode!(%{
        base_resp: %{status_code: 0},
        data: %{status: 2, audio: "616263"},
        trace_id: "trace-final",
        extra_info: %{usage_characters: 7, audio_length: 1250}
      })

    assert {:error, %Backplane.Audio.Error{}} =
             Backplane.Audio.Stream.feed(
               decoder,
               "data: " <> event <> "\n\ndata: invalid-json\n\n"
             )

    :ok = AccessLifecycle.finish(observer, :error, 502)
    {_, event} = stop_event()
    assert event.attributes["provider_request_id"] == "trace-final"
    assert event.attributes["metadata"]["audio"]["usage_characters"] == 7
    assert event.attributes["metadata"]["audio"]["audio_seconds"] == 1.25
  end

  test "preview records have a distinct surface and operation and respect persistence toggle" do
    for {operation, expected} <- [
          speech: "audio.preview.speech",
          transcription: "audio.preview.transcriptions"
        ] do
      {:ok, observer} = AccessLifecycle.start_preview(self(), operation)
      :ok = AccessLifecycle.finish(observer, :cancelled, nil)
      {_, event} = stop_event()
      assert event.attributes["operation"] == expected
      assert event.attributes["api_surface"] == "admin_audio_preview"
      assert event.attributes["path"] == "/llama/audio"
      assert event.attributes["metadata"]["audio"]["provider_dispatched"] == "false"
      flush_logs!()
      assert log_for_request(event.attributes["request_id"]).operation == expected
    end

    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, true)
    {:ok, observer} = AccessLifecycle.start_preview(self(), :speech)
    :ok = AccessLifecycle.finish(observer, :success, nil)
    {_, event} = stop_event()
    flush_logs!()
    assert log_for_request(event.attributes["request_id"]) == nil
    Application.put_env(:backplane_telemetry, :observability_v2_test_disabled, false)
  end

  defp audio_conn(request_id) do
    conn(:post, "/v1/audio/speech", "private request body")
    |> Context.put(Context.root(request_id: request_id))
  end

  defp stop_event do
    assert_receive {:audio_stop, measurements, metadata}, 1_000
    {measurements, metadata}
  end
end
