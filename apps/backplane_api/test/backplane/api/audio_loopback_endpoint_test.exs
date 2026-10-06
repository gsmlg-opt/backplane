defmodule Backplane.Api.AudioLoopbackEndpointTest do
  use Backplane.Api.DataCase, async: false
  import Plug.Conn

  alias Backplane.Audio.{Binding, Config}
  alias Backplane.Audio.Media.{Admission, Plan, Runner, TempFiles}
  alias Backplane.LLM.{Provider, ProviderModel}
  alias Backplane.Settings.Credentials

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  defmodule PublicEndpoint do
    def init(opts), do: opts

    def call(conn, owner) do
      send(owner, {:public_request, self()})
      Backplane.Api.Endpoint.call(conn, Backplane.Api.Endpoint.init([]))
    end
  end

  defmodule NativeProvider do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, state) do
      config = Agent.get(state, & &1)
      {:ok, body, conn} = read_body(conn, length: 5_000_000)

      dispatched? =
        DynamicSupervisor.which_children(Backplane.Audio.AccessLifecycle.Supervisor)
        |> Enum.any?(fn {_, pid, _, _} ->
          try do
            state = :sys.get_state(pid)
            state.dispatched? and state.fields[:requested_model] == config[:requested_model]
          catch
            :exit, _ -> false
          end
        end)

      send(config.owner, {:dispatch_observed, dispatched?})
      send(config.owner, {:native_request, self(), conn.request_path, conn.req_headers, body})

      case config.mode do
        {:status, status} ->
          send_resp(conn, status, "private provider error")

        {:body, body} ->
          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        {:fragments, content_type, fragments} ->
          conn =
            if content_type, do: put_resp_header(conn, "content-type", content_type), else: conn

          conn = send_chunked(conn, 200)

          Enum.reduce_while(fragments, conn, fn bytes, conn ->
            case chunk(conn, bytes) do
              {:ok, conn} -> {:cont, conn}
              {:error, _} -> {:halt, conn}
            end
          end)

        :progress_only ->
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

          Enum.reduce_while(1..60, conn, fn _, conn ->
            case chunk(conn, event(1, "")) do
              {:ok, conn} ->
                Process.sleep(100)
                {:cont, conn}

              {:error, _} ->
                {:halt, conn}
            end
          end)

        :stall_before ->
          receive do
            :continue -> respond(conn, body, config)
          after
            30_000 -> send_resp(conn, 504, "stalled")
          end

        _ ->
          respond(conn, body, config)
      end
    end

    defp respond(%{request_path: "/v1/speech_to_text"} = conn, _body, _config) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{text: "Offline transcript", duration: 0.3, trace_id: "asr-offline"})
      )
    end

    defp respond(conn, body, config) do
      request = Jason.decode!(body)
      audio = Map.fetch!(config.audio, request["audio_setting"]["format"])

      if request["stream"] do
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, conn} = chunk(conn, ": heartbeat\r")
        progress? = config.mode in [:progress_empty_final, :progress_aggregate, :late_business]
        prefix = if progress?, do: event(1, ""), else: ""
        {:ok, conn} = chunk(conn, "\n\r\n" <> prefix <> event(1, audio))

        case config.mode do
          mode when mode in [:stall_after, :late_error, :late_business] ->
            receive do
              :continue -> :ok
            after
              30_000 -> :ok
            end

          _ ->
            :ok
        end

        conn =
          if config.mode == :long_stream do
            Enum.reduce_while(1..20_000, conn, fn _, acc ->
              case chunk(acc, event(1, audio)) do
                {:ok, next} -> {:cont, next}
                {:error, _} -> {:halt, acc}
              end
            end)
          else
            conn
          end

        final =
          case config.mode do
            :late_error ->
              "data: invalid-json\r\n\r\n"

            :late_business ->
              "data: " <>
                Jason.encode!(%{
                  base_resp: %{status_code: 1004, status_msg: "private native-offline-secret"},
                  data: %{status: 1, audio: ""}
                }) <> "\r\n\r\n"

            :progress_empty_final ->
              event(2, "")

            _ ->
              event(2, audio)
          end

        final = if progress?, do: event(1, "") <> final, else: final

        case chunk(conn, final) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
      else
        body =
          Jason.encode!(%{
            base_resp: %{status_code: 0},
            data: %{audio: Base.encode16(audio)},
            trace_id: "tts-offline",
            extra_info: %{usage_characters: 5}
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      end
    end

    defp event(status, bytes),
      do:
        "data: " <>
          Jason.encode!(%{
            base_resp: %{status_code: 0},
            data: %{status: status, audio: Base.encode16(bytes)},
            trace_id: "tts-offline",
            extra_info: %{usage_characters: 5, audio_length: 300}
          }) <> "\r\n\r\n"
  end

  setup %{tmp_dir: dir} do
    observer_owner = self()
    telemetry_id = "observed_audio-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:backplane, :llm_proxy, :request, :stop],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.attributes["operation"] || "", "audio."),
            do: send(observer_owner, {:observed_audio, metadata.attributes})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    old = Application.get_env(:backplane, :auth_token)
    old_loopback = Application.get_env(:backplane_llama, :audio_allow_http_loopback)

    on_exit(fn ->
      restore(:backplane, :auth_token, old)
      restore(:backplane_llama, :audio_allow_http_loopback, old_loopback)
    end)

    Application.put_env(:backplane, :auth_token, "audio-loopback-client")
    Application.put_env(:backplane_llama, :audio_allow_http_loopback, true)
    :ok = Config.set_policy(%{})
    :ok = Config.set_enabled(true)
    assert Runner.ready?()

    for {format, codec} <- [{"flac", "flac"}, {"mp3", "libmp3lame"}] do
      {_, 0} =
        System.cmd(
          Runner.executable(:convert),
          [
            "-nostdin",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=24000:duration=0.3",
            "-c:a",
            codec,
            "-ar",
            "24000",
            "-ac",
            "1",
            Path.join(dir, "fixture.#{format}")
          ],
          stderr_to_stdout: true
        )
    end

    audio = Map.new(~w(mp3 flac), &{&1, File.read!(Path.join(dir, "fixture.#{&1}"))})
    owner = self()
    state = start_supervised!({Agent, fn -> %{mode: :normal, owner: owner, audio: audio} end})

    native =
      start_supervised!(
        Supervisor.child_spec({Bandit, plug: {NativeProvider, state}, port: 0}, id: :native)
      )

    {:ok, {_, native_port}} = ThousandIsland.listener_info(native)

    public =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {PublicEndpoint, owner}, port: 0},
          id: :public
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(public)
    credential = "audio-loopback-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(credential, "native-offline-secret", "llm")
    {:ok, provider} = Provider.create(%{name: credential, credential: credential, enabled: true})

    {:ok, model} =
      ProviderModel.create(%{provider_id: provider.id, model: "speech", enabled: true})

    for operation <- [:speech, :transcription] do
      {:ok, _} =
        Binding.create(%{
          provider_id: provider.id,
          provider_model_id: model.id,
          operation: operation,
          native_protocol: :minimax,
          api_origin: "http://127.0.0.1:#{native_port}",
          enabled: true,
          capabilities: %{}
        })
    end

    :ok =
      Config.set_voices(%{
        provider.name => %{"aliases" => %{"default" => "native-voice"}, "allow_native" => false}
      })

    Agent.update(state, &Map.put(&1, :requested_model, "#{provider.name}/speech"))

    %{
      base: "http://127.0.0.1:#{port}",
      port: port,
      model: "#{provider.name}/speech",
      state: state,
      audio: audio,
      dir: dir
    }
  end

  test "six public speech formats contain decodable media with correct geometry", ctx do
    for {format, profile} <- Plan.speech_profiles() do
      response = speech(ctx, format, "gzip")
      assert response.status == 200
      assert response.headers["content-type"] == [profile.mime]
      refute Map.has_key?(response.headers, "content-encoding")
      assert response.headers["x-request-id"] != []
      assert_receive {:native_request, _, "/v1/t2a_v2", headers, body}

      assert List.keyfind(headers, "authorization", 0) |> elem(1) ==
               "Bearer native-offline-secret"

      request = Jason.decode!(body)
      assert request["voice_setting"] == %{"voice_id" => "native-voice", "speed" => 1.0}
      assert request["audio_setting"]["sample_rate"] == 24_000
      assert request["audio_setting"]["format"] == if(format == "mp3", do: "mp3", else: "flac")
      if format == "mp3", do: assert(response.body == ctx.audio["mp3"])
      attrs = observed("audio.speech", "success")
      assert attrs["response_bytes"] == byte_size(response.body)
      assert attrs["provider_request_id"] == "tts-offline"
      audio = attrs["metadata"]["audio"]
      assert audio["usage_characters"] == 5
      assert audio["input_characters"] == 5
      assert audio["sample_rate"] == profile.rate
      assert audio["channels"] == 1
      assert audio["output_format"] == format
      assert audio["upstream_ms"] >= 0
      assert audio["first_byte_ms"] >= 0

      if format != "mp3" do
        assert audio["probe_ms"] >= 0
        assert audio["conversion_ms"] >= 0
        assert audio["audio_seconds"] > 0
      end

      assert_receive {:dispatch_observed, true}
      assert_media(response.body, format, ctx.dir)
      clean!()
    end
  end

  test "ASR JSON and text use native multipart bytes, language header and provider credential",
       ctx do
    for format <- ["json", "text"] do
      response = asr(ctx, format)
      assert response.status == 200

      assert response.body ==
               if(format == "json",
                 do: ~s({"text":"Offline transcript"}),
                 else: "Offline transcript"
               )

      assert_receive {:native_request, _, "/v1/speech_to_text", headers, body}

      assert List.keyfind(headers, "authorization", 0) |> elem(1) ==
               "Bearer native-offline-secret"

      assert List.keyfind(headers, "language", 0) |> elem(1) == "en"
      assert body =~ ~s(name="model")
      assert body =~ ~s(name="response_format")
      assert body =~ ctx.audio["flac"]

      assert List.keyfind(headers, "content-length", 0) |> elem(1) ==
               Integer.to_string(byte_size(body))

      attrs = observed("audio.transcriptions", "success")
      assert attrs["response_bytes"] == byte_size(response.body)
      assert attrs["request_bytes"] == byte_size(ctx.audio["flac"])
      assert attrs["provider_request_id"] == "asr-offline"
      audio = attrs["metadata"]["audio"]
      assert audio["audio_seconds"] == 0.3
      assert audio["probe_ms"] >= 0
      assert audio["conversion_ms"] >= 0
      assert audio["strategy"] == "passthrough"
      assert audio["sample_rate"] == 24000
      assert_receive {:dispatch_observed, true}
      refute body =~ "audio-loopback-client"
      clean!()
    end
  end

  test "native business errors, malformed JSON and hex, empty audio and HTTP errors are sanitized",
       ctx do
    for mode <- [
          {:body, ~s({"base_resp":{"status_code":1004},"private":"native-offline-secret"})},
          {:body, "private invalid JSON"},
          {:body, ~s({"base_resp":{"status_code":0},"data":{"audio":"xz"}})},
          {:body, ~s({"base_resp":{"status_code":0},"data":{"audio":""}})},
          {:status, 401},
          {:status, 429},
          {:status, 302}
        ] do
      Agent.update(ctx.state, &%{&1 | mode: mode})
      response = speech(ctx, "wav")
      assert response.status == if(mode == {:status, 429}, do: 429, else: 502)
      assert is_map(Jason.decode!(response.body)["error"])
      refute response.body =~ "private"
      refute response.body =~ "native-offline-secret"
      observed("audio.speech", "error")
      clean!()
    end
  end

  @tag :stream_response_classification
  test "streamed speech classifies fragmented JSON business rejections before audio commitment",
       ctx do
    for content_type <- ["Application/JSON; charset=utf-8", "application/problem+json"] do
      body =
        ~s({\n\n"base_resp":{"status_code":1004,"status_msg":"native-offline-secret"}})

      fragments = for <<byte <- body>>, do: <<byte>>
      Agent.update(ctx.state, &%{&1 | mode: {:fragments, content_type, fragments}})
      assert_stream_rejection(ctx, "audio_provider_error")
    end
  end

  @tag :stream_response_classification
  test "streamed speech rejects malformed or successful JSON and unexpected response types",
       ctx do
    rejected = ~s({"base_resp":{"status_code":1004}})

    for {content_type, body} <- [
          {"application/json", "private invalid JSON native-offline-secret"},
          {"application/json", ~s({"base_resp":{"status_code":0},"data":{"audio":"ff"}})},
          {"application/json", ~s({"base_resp":{"status_code":"1004"}})},
          {"application/json", ""},
          {"text/plain", rejected},
          {nil, rejected}
        ] do
      Agent.update(ctx.state, &%{&1 | mode: {:fragments, content_type, [body]}})
      assert_stream_rejection(ctx, "audio_invalid_response")
    end
  end

  @tag :stream_response_classification
  test "streamed JSON rejection capture respects both 64 KiB and a smaller event limit", ctx do
    for {limit, event_limit} <- [{65_536, 1_000_000}, {1024, 1024}] do
      :ok = Config.set_policy(%{"max_provider_event_bytes" => event_limit})

      for {size, code} <- [
            {limit, "audio_provider_error"},
            {limit + 1, "audio_invalid_response"}
          ] do
        empty = Jason.encode!(%{base_resp: %{status_code: 1004}, private: ""})

        body =
          Jason.encode!(%{
            base_resp: %{status_code: 1004},
            private: String.duplicate("x", size - byte_size(empty))
          })

        assert byte_size(body) == size
        Agent.update(ctx.state, &%{&1 | mode: {:fragments, "application/json", [body]}})
        assert_stream_rejection(ctx, code)
      end
    end
  end

  test "missing transcript and native ASR business failure never fabricate text", ctx do
    for body <- [
          "{}",
          ~s({"text":null}),
          ~s({"text":"secret transcript","base_resp":{"status_code":9}}),
          "bad JSON"
        ] do
      Agent.update(ctx.state, &%{&1 | mode: {:body, body}})
      response = asr(ctx, "json")
      assert response.status == 502
      refute response.body =~ "secret transcript"
      clean!()
    end
  end

  test "first MP3 chunk reaches client before stalled provider completes, without aggregate duplication",
       ctx do
    Agent.update(ctx.state, &%{&1 | mode: :stall_after})
    {conn, ref} = streaming_request(ctx)
    {conn, events} = until_data(conn, ref)
    assert Enum.any?(events, &match?({:status, ^ref, 200}, &1))
    assert_receive {:native_request, native, _, _, _}
    assert IO.iodata_to_binary(for {:data, ^ref, bytes} <- events, do: bytes) == ctx.audio["mp3"]
    send(native, :continue)
    {_conn, rest} = until_done(conn, ref)
    assert IO.iodata_to_binary(for {:data, ^ref, bytes} <- rest, do: bytes) == ""
    clean!()
  end

  test "late invalid SSE aborts committed audio without appending JSON", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :late_error})
    {conn, ref} = streaming_request(ctx)
    {conn, first_events} = until_data(conn, ref)
    assert_receive {:native_request, native, _, _, _}
    send(native, :continue)
    {events, outcome} = drain(conn, ref, first_events)
    assert outcome == :closed
    assert Enum.any?(events, &match?({:status, ^ref, 200}, &1))
    bytes = IO.iodata_to_binary(for {:data, ^ref, data} <- events, do: data)
    assert bytes == ctx.audio["mp3"]
    refute bytes =~ ~s("error")
    attrs = observed("audio.speech", "error")
    assert attrs["response_bytes"] == byte_size(bytes)
    clean!()
  end

  test "empty progress surrounds exact MP3 output with empty or aggregate completion", ctx do
    for mode <- [:progress_empty_final, :progress_aggregate] do
      Agent.update(ctx.state, &%{&1 | mode: mode})
      response = speech(ctx, "mp3")
      assert response.status == 200
      assert response.headers["content-type"] == ["audio/mpeg"]
      assert response.body == ctx.audio["mp3"]
      assert_media(response.body, "mp3", ctx.dir)
      attrs = observed("audio.speech", "success")
      assert attrs["response_bytes"] == byte_size(ctx.audio["mp3"])
      assert attrs["metadata"]["audio"]["upstream_bytes"] == byte_size(ctx.audio["mp3"])
      clean!()
    end
  end

  test "repeated empty progress cannot reset the overall deadline or commit audio", ctx do
    :ok =
      Config.set_policy(%{
        "request_timeout_ms" => 2000,
        "conversion_timeout_ms" => 1000,
        "probe_timeout_ms" => 1000
      })

    Agent.update(ctx.state, &%{&1 | mode: :progress_only})
    started = System.monotonic_time(:millisecond)
    response = speech(ctx, "mp3")
    assert System.monotonic_time(:millisecond) - started < 4500
    assert response.status == 504
    assert Jason.decode!(response.body)["error"]["code"] == "audio_timeout"
    attrs = observed("audio.speech", "timeout")
    assert attrs["metadata"]["audio"]["upstream_bytes"] in [nil, 0]
    clean!()
  end

  test "late business failure after empty progress aborts committed audio and keeps uncertainty",
       ctx do
    Agent.update(ctx.state, &%{&1 | mode: :late_business})
    {conn, ref} = streaming_request(ctx)
    {conn, first_events} = until_data(conn, ref)
    assert_receive {:native_request, native, _, _, _}
    send(native, :continue)
    {events, outcome} = drain(conn, ref, first_events)
    assert outcome == :closed
    assert Enum.any?(events, &match?({:status, ^ref, 200}, &1))
    bytes = IO.iodata_to_binary(for {:data, ^ref, data} <- events, do: data)
    assert bytes == ctx.audio["mp3"]
    refute bytes =~ "private"
    refute bytes =~ "native-offline-secret"
    attrs = observed("audio.speech", "error")
    assert attrs["error_code"] == "audio_provider_error"
    assert attrs["response_bytes"] == byte_size(bytes)
    clean!()
  end

  test "overall deadline aborts stalled provider and cleans the session", ctx do
    :ok =
      Config.set_policy(%{
        "request_timeout_ms" => 2000,
        "conversion_timeout_ms" => 1000,
        "probe_timeout_ms" => 1000
      })

    Agent.update(ctx.state, &%{&1 | mode: :stall_before})
    response = speech(ctx, "mp3")
    assert response.status == 504
    assert Jason.decode!(response.body)["error"]["code"] == "audio_timeout"
    observed("audio.speech", "timeout")
    clean!()
  end

  test "client disconnect before and after commitment cancels upstream and cleans media", ctx do
    for mode <- [:stall_before, :stall_after] do
      Agent.update(ctx.state, &%{&1 | mode: mode})
      {conn, ref} = streaming_request(ctx)
      assert_receive {:public_request, request_owner}
      assert_receive {:native_request, _native, _, _, _}, 15_000
      conn = if mode == :stall_after, do: elem(until_data(conn, ref), 0), else: conn
      request_ref = Process.monitor(request_owner)
      Mint.HTTP.close(conn)
      assert_receive {:DOWN, ^request_ref, :process, ^request_owner, _}, 5000
      observed("audio.speech", "cancelled")
      clean!()
    end
  end

  test "slow client retains bounded worker demand and cancels without leaked sessions", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :long_stream})

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false, recbuf: 1024])

    :ok = :gen_tcp.send(socket, wire_request(ctx))
    assert_receive {:public_request, owner}
    assert_receive {:native_request, _, _, _, _}, 15_000
    Process.sleep(500)
    workers = Task.Supervisor.children(Backplane.Audio.Media.TaskSupervisor)
    assert workers != []

    for pid <- [owner | workers] do
      {:message_queue_len, count} = Process.info(pid, :message_queue_len)
      assert count <= 4
      {:memory, bytes} = Process.info(pid, :memory)
      assert bytes < 8_000_000
    end

    :gen_tcp.close(socket)
    clean!()
  end

  test "HTTP1 restores passive mode for sequential keepalive and two pipelined requests", ctx do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", ctx.port, mode: :passive)
    body = Jason.encode!(%{model: ctx.model, input: "Hello", voice: "default"})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer audio-loopback-client"}
    ]

    {:ok, conn, first} = Mint.HTTP.request(conn, "POST", "/v1/audio/speech", headers, body)
    {conn, events} = until_done(conn, first)
    assert {:status, first, 200} in events
    {:ok, conn, second} = Mint.HTTP.request(conn, "POST", "/v1/audio/speech", headers, body)
    {conn, events} = until_done(conn, second)
    assert {:status, second, 200} in events
    Mint.HTTP.close(conn)
    clean!()

    Agent.update(ctx.state, &%{&1 | mode: :stall_after})
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false])
    flush_native_requests()
    :ok = :gen_tcp.send(socket, wire_request(ctx))
    # The first request's provider is blocked while the next request arrives.
    # This specifically exercises active-once buffering, not initial parser buffering.
    native = wait_stalled_native()
    :ok = :gen_tcp.send(socket, wire_request(ctx))
    Agent.update(ctx.state, &%{&1 | mode: :normal})
    send(native, :continue)
    response = recv_two_responses(socket, "")
    assert length(:binary.matches(response, "HTTP/1.1 200")) == 2
    :gen_tcp.close(socket)
    clean!()
  end

  test "excess pipelined bytes abort the audio request and release its session", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :stall_before})
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", ctx.port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, wire_request(ctx))
    assert_receive {:public_request, owner}
    assert_receive {:native_request, _, _, _, _}, 15_000
    monitor = Process.monitor(owner)
    :ok = :gen_tcp.send(socket, String.duplicate("x", 65_537))
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5000
    :gen_tcp.close(socket)
    clean!()
  end

  test "ASR failure after dispatch preserves uncertain execution metadata", ctx do
    Agent.update(ctx.state, &%{&1 | mode: {:body, "{}"}})
    {:ok, session} = Backplane.Audio.Media.Session.start(self(), Config.policy())

    {:ok, request} =
      Backplane.Audio.Request.transcription(%{
        "model" => ctx.model,
        "file" => %Plug.Upload{
          path: Path.join(ctx.dir, "fixture.flac"),
          filename: "clip.flac",
          content_type: "audio/flac"
        }
      })

    {:ok, resolution} = Backplane.Audio.Resolver.resolve(:transcription, ctx.model)

    try do
      assert {:error, %{code: "audio_invalid_response"}, %{uncertain_execution: true}} =
               Backplane.Audio.Transcription.run(
                 request,
                 resolution,
                 session,
                 System.monotonic_time(:millisecond) + 15_000
               )

      assert_receive {:native_request, _, "/v1/speech_to_text", _, _}
    after
      Backplane.Audio.Media.Session.release(session)
    end

    clean!()
  end

  test "HTTP2 reset before commitment cancels only the request stream", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :stall_before})
    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", ctx.port, mode: :passive)
    body = Jason.encode!(%{model: ctx.model, input: "Hello", voice: "default"})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer audio-loopback-client"}
    ]

    {:ok, conn, ref} = Mint.HTTP.request(conn, "POST", "/v1/audio/speech", headers, body)
    assert_receive {:public_request, owner}
    assert_receive {:native_request, _, _, _, _}, 15_000
    monitor = Process.monitor(owner)
    {:ok, conn} = Mint.HTTP2.cancel_request(conn, ref)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5000
    clean!()
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/v1/models", headers, nil)
    {conn, events} = until_done(conn, ref)
    assert {:status, ref, 200} in events
    Mint.HTTP.close(conn)
  end

  test "HTTP2 flow-control stalled delivery obeys deadline without closing its connection", ctx do
    :ok =
      Config.set_policy(%{
        "request_timeout_ms" => 3000,
        "conversion_timeout_ms" => 1000,
        "probe_timeout_ms" => 1000
      })

    {:ok, conn} = Mint.HTTP2.connect(:http, "127.0.0.1", ctx.port, mode: :passive)
    {:ok, conn} = Mint.HTTP2.put_settings(conn, initial_window_size: 1)
    body = Jason.encode!(%{model: ctx.model, input: "Hello", voice: "default"})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer audio-loopback-client"}
    ]

    {:ok, conn, _ref} = Mint.HTTP.request(conn, "POST", "/v1/audio/speech", headers, body)
    assert_receive {:public_request, owner}
    assert_receive {:native_request, _, _, _, _}, 15_000
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5000
    clean!()
    {:ok, conn} = Mint.HTTP2.put_settings(conn, initial_window_size: 65_535)
    {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/v1/models", headers, nil)
    {conn, events} = until_done(conn, ref)
    assert {:status, ref, 200} in events
    Mint.HTTP.close(conn)
  end

  test "generic Plug adapters are not assigned a request-killing deadline guard" do
    conn = Plug.Test.conn(:get, "/")
    assert {:ok, nil} = Backplane.Audio.Downstream.start(conn, 0)
    assert :ok = Backplane.Audio.Downstream.deliver(nil, 0, fn -> :ok end)
    assert {:ok, ^conn} = Backplane.Audio.Downstream.restore(conn, nil)
  end

  test "owner crash terminates the upstream worker outside its consumer wait", ctx do
    Agent.update(ctx.state, &%{&1 | mode: :stall_before})
    {conn, _ref} = streaming_request(ctx)
    assert_receive {:public_request, owner}
    assert_receive {:native_request, _, _, _, _}, 15_000
    workers = Task.Supervisor.children(Backplane.Audio.Media.TaskSupervisor)
    refs = for pid <- workers, do: {pid, Process.monitor(pid)}
    Process.exit(owner, :kill)
    for {pid, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^pid, _}, 5000)
    Mint.HTTP.close(conn)
    clean!()
  end

  test "lossy-only binding cannot silently convert MP3 to AAC", ctx do
    binding = Enum.find(Binding.list(), &(&1.operation == :speech))
    {:ok, _} = Binding.update(binding, %{capabilities: %{"native_formats" => ["mp3"]}})
    response = speech(ctx, "aac")
    assert response.status == 503
    refute_receive {:native_request, _, _, _, _}, 50
    clean!()
  end

  test "pinned OpenAI SDK exercises binary speech, streaming speech and both transcription responses",
       ctx do
    python =
      System.get_env("BACKPLANE_AUDIO_SDK_PYTHON") || "/tmp/backplane-audio-sdk-venv/bin/python"

    assert File.exists?(python), "Install OpenAI 2.26.0 and set BACKPLANE_AUDIO_SDK_PYTHON"
    script = Path.expand("../../support/audio_sdk_smoke.py", __DIR__)

    {output, code} =
      System.cmd(
        python,
        [script, ctx.base, ctx.model, Path.join(ctx.dir, "fixture.flac"), ctx.dir],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "OpenAI 2.26.0 audio SDK conformance passed"

    for format <- ~w(wav mp3),
        do: assert_media(File.read!(Path.join(ctx.dir, "sdk.#{format}")), format, ctx.dir)

    clean!()
  end

  defp assert_stream_rejection(ctx, code) do
    response = speech(ctx, "mp3")
    assert response.status == 502
    assert [content_type] = response.headers["content-type"]
    assert String.starts_with?(content_type, "application/json")
    assert Jason.decode!(response.body)["error"]["code"] == code
    refute response.body =~ "native-offline-secret"
    refute response.body =~ "private"
    attrs = observed("audio.speech", "error")
    assert attrs["error_code"] == code
    assert attrs["metadata"]["audio"]["stream"] == "true"
    assert attrs["metadata"]["audio"]["upstream_bytes"] in [nil, 0]
    assert_receive {:dispatch_observed, true}
    clean!()
  end

  defp observed(operation, outcome) do
    assert_receive {:observed_audio, attrs}, 2000
    assert attrs["operation"] == operation
    assert attrs["outcome"] == outcome
    assert attrs["input_tokens"] == nil
    assert attrs["output_tokens"] == nil
    assert attrs["metadata"]["audio"]["provider_dispatched"] == "true"
    assert attrs["metadata"]["audio"]["paid_uncertain"] == to_string(outcome != "success")
    refute inspect(attrs) =~ "native-offline-secret"
    refute inspect(attrs) =~ "Offline transcript"
    refute_receive {:observed_audio, _}, 20
    attrs
  end

  defp speech(ctx, format, accept_encoding \\ "identity") do
    Req.post!(ctx.base <> "/v1/audio/speech",
      json: %{model: ctx.model, input: "Hello", voice: "default", response_format: format},
      headers: [
        {"authorization", "Bearer audio-loopback-client"},
        {"accept-encoding", accept_encoding}
      ],
      retry: false,
      decode_body: false,
      compressed: false,
      receive_timeout: 30_000
    )
  end

  defp asr(ctx, format) do
    Req.post!(ctx.base <> "/v1/audio/transcriptions",
      form_multipart: [
        model: ctx.model,
        response_format: format,
        language: "en",
        file:
          {File.stream!(Path.join(ctx.dir, "fixture.flac")),
           filename: "clip.flac", content_type: "application/octet-stream"}
      ],
      headers: [
        {"authorization", "Bearer audio-loopback-client"},
        {"accept-encoding", "identity"}
      ],
      retry: false,
      decode_body: false,
      compressed: false,
      receive_timeout: 30_000
    )
  end

  defp streaming_request(ctx) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", ctx.port, mode: :passive)

    body =
      Jason.encode!(%{model: ctx.model, input: "Hello", voice: "default", response_format: "mp3"})

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "POST",
        "/v1/audio/speech",
        [{"content-type", "application/json"}, {"authorization", "Bearer audio-loopback-client"}],
        body
      )

    {conn, ref}
  end

  defp until_data(conn, ref, acc \\ []) do
    {:ok, conn, events} = Mint.HTTP.recv(conn, 0, 15_000)
    acc = acc ++ events

    if Enum.any?(events, &match?({:data, ^ref, _}, &1)),
      do: {conn, acc},
      else: until_data(conn, ref, acc)
  end

  defp until_done(conn, ref, acc \\ []) do
    {:ok, conn, events} = Mint.HTTP.recv(conn, 0, 15_000)
    acc = acc ++ events

    if Enum.any?(events, &match?({:done, ^ref}, &1)),
      do: {conn, acc},
      else: until_done(conn, ref, acc)
  end

  defp drain(conn, ref, acc) do
    case Mint.HTTP.recv(conn, 0, 15_000) do
      {:ok, next, events} ->
        if Enum.any?(events, &match?({:done, ^ref}, &1)),
          do: {acc ++ events, :done},
          else: drain(next, ref, acc ++ events)

      {:error, _, _, events} ->
        {acc ++ events, :closed}
    end
  end

  defp wire_request(ctx) do
    body = Jason.encode!(%{model: ctx.model, input: "Hello", voice: "default"})

    "POST /v1/audio/speech HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer audio-loopback-client\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
      body
  end

  defp flush_native_requests do
    receive do
      {:native_request, _, _, _, _} -> flush_native_requests()
    after
      0 -> :ok
    end
  end

  defp wait_stalled_native do
    assert_receive {:native_request, pid, _, _, _}, 15_000
    pid
  end

  defp recv_two_responses(socket, acc) do
    if length(:binary.matches(acc, "HTTP/1.1 200")) == 2 and
         length(:binary.matches(acc, "\r\n0\r\n\r\n")) == 2 do
      acc
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 15_000)
      recv_two_responses(socket, acc <> bytes)
    end
  end

  defp assert_media(bytes, format, dir) do
    profile = Plan.speech_profiles()[format]
    path = Path.join(dir, "out.#{format}")
    File.write!(path, bytes)
    raw = if format == "pcm", do: ["-f", "s16le", "-ar", "24000", "-ac", "1"], else: []

    {decoded, code} =
      System.cmd(
        Runner.executable(:convert),
        ["-nostdin", "-v", "error"] ++
          raw ++ ["-i", path, "-f", "s16le", "-ac", "1", "-ar", "24000", "-"],
        stderr_to_stdout: true
      )

    assert code == 0
    assert byte_size(decoded) > 10_000
    assert abs(byte_size(decoded) / 48_000 - 0.3) < 0.15

    if format == "pcm" do
      assert rem(byte_size(bytes), 2) == 0
    else
      {json, 0} =
        System.cmd(Runner.executable(:probe), [
          "-v",
          "error",
          "-show_streams",
          "-of",
          "json",
          path
        ])

      [stream] = Jason.decode!(json)["streams"]
      assert stream["sample_rate"] == Integer.to_string(profile.rate)
      assert stream["channels"] == 1
      assert stream["codec_name"] == if(format == "wav", do: "pcm_s16le", else: format)
    end
  end

  defp clean! do
    eventually(fn ->
      Admission.counts() == %{operation: 0, upload: 0, media: 0} and
        TempFiles.usage() == %{requests: 0, reserved: 0}
    end)
  end

  defp eventually(fun, attempts \\ 500)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
