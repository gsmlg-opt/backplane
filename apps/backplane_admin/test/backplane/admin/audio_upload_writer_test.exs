defmodule Backplane.Admin.AudioUploadWriterTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.{AudioPreview, AudioUploadWriter}
  alias Backplane.Audio.Config

  setup do
    :ok = Config.set_policy(%{})
    {:ok, preview} = AudioPreview.start(self(), :transcription)
    on_exit(fn -> if Process.alive?(preview), do: AudioPreview.cancel(preview) end)
    %{preview: preview, deadline: System.monotonic_time(:millisecond) + 10_000}
  end

  test "init refuses absent, dead or expired admission before creating a file", ctx do
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}

    for opts <- [
          [],
          [session: nil, deadline: ctx.deadline],
          [session: dead, deadline: ctx.deadline],
          [session: ctx.preview, deadline: System.monotonic_time(:millisecond) - 1]
        ] do
      assert {:error, :upload_not_admitted} = AudioUploadWriter.init(opts)
    end
  end

  test "admitted writes retain default metadata and private file until consumption", ctx do
    {:ok, state} = AudioUploadWriter.init(session: ctx.preview, deadline: ctx.deadline)
    %{path: path} = AudioUploadWriter.meta(state)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert {:ok, state} = AudioUploadWriter.write_chunk("first", state)
    assert {:ok, state} = AudioUploadWriter.write_chunk("second", state)
    assert {:ok, _} = AudioUploadWriter.close(state, :done)
    assert File.read!(path) == "firstsecond"
    File.rm!(path)
  end

  test "loss of admission or expiry prevents subsequent bytes and cancellation removes file",
       ctx do
    for reason <- [:expired, :dead] do
      {:ok, state} = AudioUploadWriter.init(session: ctx.preview, deadline: ctx.deadline)
      %{path: path} = AudioUploadWriter.meta(state)
      assert {:ok, state} = AudioUploadWriter.write_chunk("accepted", state)

      state =
        case reason do
          :dead ->
            ref = Process.monitor(ctx.preview)
            AudioPreview.cancel(ctx.preview)
            assert_receive {:DOWN, ^ref, :process, _, _}
            state

          :expired ->
            %{state | deadline: System.monotonic_time(:millisecond) - 1}
        end

      assert {:error, :upload_not_admitted, state} =
               AudioUploadWriter.write_chunk("rejected", state)

      assert File.read!(path) == "accepted"
      assert {:ok, _} = AudioUploadWriter.close(state, :cancel)
      refute File.exists?(path)
    end
  end

  test "default upload ownership deletes the file when the uploader exits", ctx do
    owner = self()

    pid =
      spawn(fn ->
        {:ok, state} = AudioUploadWriter.init(session: ctx.preview, deadline: ctx.deadline)
        %{path: path} = AudioUploadWriter.meta(state)
        send(owner, {:path, path})

        receive do
          :stop -> AudioUploadWriter.close(state, :cancel)
        end
      end)

    assert_receive {:path, path}
    assert File.exists?(path)
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute File.exists?(path)
  end
end
