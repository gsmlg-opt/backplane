defmodule Backplane.Audio.Media.LifecycleTest do
  use ExUnit.Case, async: false

  alias Backplane.Audio.Config
  alias Backplane.Audio.Media.{Admission, Capabilities, Probe, Runner, Session, TempFiles}

  setup do
    assert Runner.ready?(), "real FFmpeg/ffprobe and native confinement are required"
    {:ok, policy: Config.policy()}
  end

  test "real readiness uses every codec and releases all storage", %{policy: policy} do
    before = TempFiles.usage()

    assert %{ready?: true, sandbox: :ready, formats: formats, asr_formats: asr_formats} =
             Capabilities.probe(policy)

    assert Enum.sort(Map.keys(asr_formats)) ==
             ~w(flac/flac m4a/aac m4a/alac mp3/mp3 mp4/aac mpeg/mp2 mpga/mp3 ogg/opus ogg/vorbis wav/pcm_s16le webm/opus)

    assert Enum.all?(asr_formats, fn {_, value} -> value end)
    assert Enum.sort(Map.keys(formats)) == ~w(aac flac mp3 opus pcm wav)
    assert Enum.all?(formats, fn {_, value} -> value end)
    assert TempFiles.usage() == before
  end

  test "request readiness checks only its declared operation and full readiness includes ASR", %{
    policy: policy
  } do
    before = TempFiles.usage()

    assert %{ready?: true, formats: speech, asr_formats: %{}} =
             Capabilities.probe(policy, :speech)

    assert map_size(speech) == 6

    assert %{ready?: true, formats: %{"flac" => true}, asr_formats: %{}} =
             Capabilities.probe(policy, :transcription)

    # The checked-in Vorbis fixture has two channels. Its real probe must fail
    # under a mono-only policy even when every speech output remains available.
    assert %{ready?: false, formats: formats, asr_formats: asr} =
             Capabilities.probe(Map.put(policy, "max_channels", 1))

    assert Enum.all?(formats, fn {_, ready?} -> ready? end)
    assert asr["ogg/vorbis"] == false
    assert asr["m4a/alac"] == true
    assert asr["mpeg/mp2"] == true
    assert TempFiles.usage() == before
  end

  test "confirmed cleanup waits for launcher exit and leaves no caller port messages", %{
    policy: policy
  } do
    root = private_root()
    mock = Path.join(root, "launcher")

    File.write!(
      mock,
      "#!/bin/sh\nprintf '\\000\\000\\000\\007X\\000\\000\\000\\000\\000\\001'\nsleep 0.1\n"
    )

    File.chmod!(mock, 0o700)
    previous = Process.flag(:trap_exit, true)

    try do
      with_env("BACKPLANE_AUDIO_LAUNCHER_PATH", mock, fn ->
        {:ok, handle} = TempFiles.create(self(), policy)
        started = System.monotonic_time(:millisecond)
        assert {:ok, :ready} = Runner.selftest(handle, policy)
        assert System.monotonic_time(:millisecond) - started >= 100
        refute_port_messages()
        assert :ok = TempFiles.release(handle)
      end)

      {:ok, handle} = TempFiles.create(self(), policy)
      assert {:ok, :ready} = Runner.selftest(handle, policy)
      refute_port_messages()
      assert :ok = TempFiles.release(handle)
    after
      Process.flag(:trap_exit, previous)
      File.rm_rf!(root)
    end
  end

  test "failed decoded reservation cannot subtract existing input reservations", %{policy: policy} do
    policy = Map.put(policy, "temporary_storage_bytes", 2_000_000)
    {:ok, handle} = TempFiles.create(self(), policy)
    :ok = TempFiles.reserve(handle, 100_000)
    {:ok, input} = TempFiles.path(handle, :input)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.2", "-c:a", "flac", "-f", "flac", input])
    before = TempFiles.usage().reserved

    assert {:error, %{code: "audio_storage_exhausted"}} =
             Probe.inspect(handle, input, %{
               purpose: :transcription,
               extension: "flac",
               policy: policy
             })

    assert TempFiles.usage().reserved == before
    TempFiles.release(handle)
  end

  test "native worker thread exhaustion terminates media and confirms cleanup", %{policy: policy} do
    before = Admission.counts().media
    {:ok, handle} = TempFiles.create(self(), policy)
    launcher = Runner.launcher()

    with_env("BACKPLANE_AUDIO_FFMPEG_PATH", launcher, fn ->
      command = %{
        mode: :convert,
        args: ["--internal-thread-flood"],
        output: nil,
        max_bytes: 1_000_000
      }

      assert {:error, %{code: "audio_resource_limit"}} = Runner.run(handle, command, policy)
      assert File.read!(handle.dir <> ".cleanup-confirmed") == "clean\n"
      assert Admission.counts().media == before
      assert :ok = TempFiles.release(handle)
      refute File.exists?(handle.dir)
    end)
  end

  test "uncertain terminal keeps files and capacity until trusted cleanup proof", %{
    policy: policy
  } do
    root = private_root()
    mock = Path.join(root, "launcher")
    # packet4 X: unknown exit, no signal, cleanup unconfirmed. This mock starts
    # no OS media worker; its explicit proof below simulates a late guardian.
    File.write!(mock, "#!/bin/sh\nprintf '\\000\\000\\000\\007X\\377\\377\\377\\377\\000\\000'\n")
    File.chmod!(mock, 0o700)

    with_env("BACKPLANE_AUDIO_LAUNCHER_PATH", mock, fn ->
      {:ok, handle} = TempFiles.create(self(), policy)
      :ok = TempFiles.reserve(handle, 123)
      before = Admission.counts().media
      assert {:error, %{code: "audio_cleanup_uncertain"}} = Runner.selftest(handle, policy)
      assert Admission.counts().media == before + 1
      :ok = TempFiles.release(handle)
      assert File.dir?(handle.dir)
      assert TempFiles.usage().reserved >= 123
      File.write!(handle.dir <> ".cleanup-confirmed", "clean\n")

      assert eventually(fn ->
               not File.exists?(handle.dir) and Admission.counts().media == before
             end)
    end)

    File.rm_rf!(root)
  end

  test "a signal exit never reports successful readiness", %{policy: policy} do
    root = private_root()
    mock = Path.join(root, "launcher")
    File.write!(mock, "#!/bin/sh\nprintf '\\000\\000\\000\\007X\\000\\000\\000\\000\\011\\001'\n")
    File.chmod!(mock, 0o700)

    with_env("BACKPLANE_AUDIO_LAUNCHER_PATH", mock, fn ->
      {:ok, handle} = TempFiles.create(self(), policy)
      assert {:error, %{code: "audio_media_failed"}} = Runner.selftest(handle, policy)
      TempFiles.release(handle)
    end)

    File.rm_rf!(root)
  end

  test "actual native deadline and cancellation leave no pinned storage", %{policy: policy} do
    for mode <- [:deadline, :cancel] do
      owner = self()

      policy =
        if mode == :deadline, do: Map.put(policy, "conversion_timeout_ms", 100), else: policy

      task =
        Task.async(fn ->
          {:ok, handle} = TempFiles.create(self(), policy)
          send(owner, {:handle, handle})
          {:ok, output} = TempFiles.path(handle, :output)
          result = Runner.run(handle, slow_command(output), policy)
          TempFiles.release(handle)
          result
        end)

      assert_receive {:handle, handle}
      assert eventually(fn -> Admission.counts().media > 0 end)
      if mode == :cancel, do: send(task.pid, :cancel)
      assert {:error, %{code: code}} = Task.await(task, 10_000)
      assert code == if(mode == :cancel, do: "audio_cancelled", else: "audio_media_timeout")
      assert eventually(fn -> not File.exists?(handle.dir) and Admission.counts().media == 0 end)
    end
  end

  test "Runner owner death and capability-style direct ownership retain until native cleanup", %{
    policy: policy
  } do
    parent = self()

    worker =
      spawn(fn ->
        {:ok, handle} = TempFiles.create(self(), policy)
        {:ok, output} = TempFiles.path(handle, :output)
        send(parent, {:direct, handle})
        Runner.run(handle, slow_command(output), policy)
      end)

    assert_receive {:direct, handle}
    assert eventually(fn -> native_port?(worker) end)
    Process.exit(worker, :kill)
    assert eventually(fn -> not File.exists?(handle.dir) and Admission.counts().media == 0 end)
  end

  test "session task crash quarantines its active native operation", %{policy: policy} do
    {:ok, session} = Session.start(self(), policy)
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 1_000_000)
    # Real-time input makes the probe task observable without large fixture files.
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=30", "-c:a", "flac", "-f", "flac", input])
    handle = :sys.get_state(session).handle
    caller = Task.async(fn -> Session.prepare(session, :transcription, input, "flac") end)

    assert eventually(fn ->
             case :sys.get_state(session).active do
               %{pid: pid} ->
                 if native_port?(pid),
                   do:
                     (
                       Process.exit(pid, :kill)
                       true
                     ),
                   else: false

               _ ->
                 false
             end
           end)

    assert {:error, %{code: "audio_cleanup_uncertain"}} = Task.await(caller, 10_000)
    assert eventually(fn -> not File.exists?(handle.dir) and Admission.counts().media == 0 end)
  end

  test "owner death cancels a session asynchronously and preserves finished artifacts until release",
       %{policy: policy} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, session} = Session.start(owner, policy)
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 1_000_000)

    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "sine=duration=1",
      "-c:a",
      "flac",
      "-ar",
      "24000",
      "-ac",
      "1",
      "-f",
      "flac",
      input
    ])

    assert {:ok, artifact} = Session.prepare(session, :speech, input, "wav")
    send(TempFiles, :janitor_tick)
    assert TempFiles.ready?()
    assert File.regular?(artifact.path)
    # A sender can read the complete finalized body before releasing ownership.
    assert byte_size(File.read!(artifact.path)) == artifact.bytes
    send(owner, :stop)
    assert eventually(fn -> not Process.alive?(session) and not File.exists?(artifact.path) end)
  end

  test "media subtree restart waits for guardian cleanup before readmission", %{policy: policy} do
    parent = self()

    worker =
      spawn(fn ->
        {:ok, handle} = TempFiles.create(self(), policy)
        {:ok, output} = TempFiles.path(handle, :output)
        send(parent, {:restart_handle, handle})
        Runner.run(handle, slow_command(output), policy)
      end)

    assert_receive {:restart_handle, handle}
    assert eventually(fn -> native_port?(worker) end)
    old_manager = Process.whereis(TempFiles)
    old_admission = Process.whereis(Admission)
    Process.exit(worker, :kill)
    Process.exit(old_admission, :kill)

    assert eventually(fn ->
             current = Process.whereis(TempFiles)

             current != nil and current != old_manager and TempFiles.ready?() and
               not File.exists?(handle.dir)
           end)

    assert TempFiles.usage() == %{requests: 0, reserved: 0}
    assert Admission.counts() == %{operation: 0, upload: 0, media: 0}
  end

  test "active session owner death cancels native work and reclaims its operation", %{
    policy: policy
  } do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, session} = Session.start(owner, policy)
    {:ok, input} = Session.input_path(session)
    handle = :sys.get_state(session).handle
    :ok = Session.reserve_input(session, 1_000_000)
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=30", "-c:a", "flac", "-f", "flac", input])
    caller = Task.async(fn -> Session.prepare(session, :transcription, input, "flac") end)

    assert eventually(fn ->
             case :sys.get_state(session).active do
               %{pid: pid} ->
                 if native_port?(pid),
                   do:
                     (
                       send(owner, :stop)
                       true
                     ),
                   else: false

               _ ->
                 false
             end
           end)

    assert {:error, %{code: "audio_cancelled"}} = Task.await(caller, 10_000)
    assert eventually(fn -> not Process.alive?(session) and not File.exists?(handle.dir) end)
    assert Admission.counts().operation == 0
  end

  test "explicit provider raw PCM geometry survives conversion", %{policy: policy} do
    {:ok, session} = Session.start(self(), policy)
    {:ok, input} = Session.input_path(session)
    :ok = Session.reserve_input(session, 48_000)

    ffmpeg!([
      "-f",
      "lavfi",
      "-i",
      "sine=duration=1:sample_rate=24000",
      "-ac",
      "1",
      "-c:a",
      "pcm_s16le",
      "-f",
      "s16le",
      input
    ])

    assert {:ok, artifact} =
             Session.prepare(session, :speech, input, "wav", %{source_format: "pcm"})

    assert artifact.plan.source.sample_rate == 24_000
    assert artifact.plan.source.duration == 1.0
    assert artifact.bytes > 48_000
    :ok = Session.release(session)
  end

  test "probe and conversion cannot resolve local or network playlist references", %{
    policy: policy
  } do
    outside = private_root()
    secret = Path.join(outside, "unrelated.wav")
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.2", "-c:a", "pcm_s16le", "-f", "wav", secret])
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)

    for source <- [secret, "http://127.0.0.1:#{port}/unrelated.wav"],
        mode <- [:probe, :convert] do
      {:ok, handle} = TempFiles.create(self(), policy)
      {:ok, playlist} = TempFiles.path(handle, :input)
      {:ok, output} = TempFiles.path(handle, :output)
      File.write!(playlist, "ffconcat version 1.0\nfile '#{source}'\n")

      input_args = [
        "-v",
        "error",
        "-protocol_whitelist",
        "file,http,tcp",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        playlist
      ]

      args =
        if mode == :probe,
          do: input_args ++ ["-show_streams", "-of", "json", "-o", output],
          else: ["-nostdin"] ++ input_args ++ ["-c:a", "pcm_s16le", "-f", "wav", output]

      assert {:error, _} =
               Runner.run(
                 handle,
                 %{mode: mode, args: args, output: output, max_bytes: 1_000_000},
                 policy
               )

      TempFiles.release(handle)
    end

    assert {:error, :timeout} = :gen_tcp.accept(socket, 50)
    :gen_tcp.close(socket)
    File.rm_rf!(outside)
  end

  test "uploaded shell metacharacters are never filesystem or process arguments", %{
    policy: policy
  } do
    root = private_root()
    source = Path.join(root, "upload")
    ffmpeg!(["-f", "lavfi", "-i", "sine=duration=0.2", "-c:a", "flac", "-f", "flac", source])
    {:ok, session} = Session.start(self(), policy)
    :ok = Session.admit_upload(session)

    upload = %Plug.Upload{
      path: source,
      filename: "../../bad';touch injected;#.flac",
      content_type: "application/octet-stream"
    }

    assert {:ok, path, _} = Session.adopt_upload(session, upload)
    assert Path.basename(path) == "input.media"
    assert {:ok, _} = Session.prepare(session, :transcription, path, "flac")
    :ok = Session.release(session)
    File.rm_rf!(root)
  end

  defp native_port?(pid) do
    case Process.info(pid, :links) do
      {:links, links} -> Enum.any?(links, &is_port/1)
      _ -> false
    end
  end

  defp slow_command(output),
    do: %{
      mode: :convert,
      args: [
        "-nostdin",
        "-v",
        "error",
        "-re",
        "-f",
        "lavfi",
        "-i",
        "sine=duration=30",
        "-c:a",
        "pcm_s16le",
        "-f",
        "wav",
        output
      ],
      output: output,
      max_bytes: 5_000_000
    }

  defp refute_port_messages do
    receive do
      {port, _message} when is_port(port) -> flunk("Runner left a port message in its caller")
      {:EXIT, port, _reason} when is_port(port) -> flunk("Runner left a port exit in its caller")
    after
      150 -> :ok
    end
  end

  defp private_root do
    path = Path.join(System.tmp_dir!(), "audio-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp with_env(key, value, fun) do
    previous = System.get_env(key)
    System.put_env(key, value)

    try do
      fun.()
    after
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end
  end

  defp ffmpeg!(args) do
    {out, code} =
      System.cmd(
        Runner.executable(:convert),
        ["-nostdin", "-hide_banner", "-v", "error", "-y"] ++ args,
        stderr_to_stdout: true
      )

    assert code == 0, out
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, n - 1)
        )
  end
end
