defmodule Backplane.Audio.Media.RunnerTest do
  use ExUnit.Case, async: false

  alias Backplane.Audio.Config
  alias Backplane.Audio.Media.{Runner, TempFiles}

  test "BEAM-hosted launcher probes and fully decodes the checked-in FLAC fixture" do
    policy = Config.policy()

    paths =
      for {kind, path} <- [
            launcher: Runner.launcher(),
            probe: Runner.executable(:probe),
            convert: Runner.executable(:convert)
          ],
          into: %{} do
        {kind,
         %{
           path: path,
           absolute: is_binary(path) and Path.type(path) == :absolute,
           regular: is_binary(path) and File.regular?(path)
         }}
      end

    assert Runner.ready?(), "Audio executable readiness failed: #{inspect(paths)}"
    {:ok, handle} = TempFiles.create(self(), policy)
    on_exit(fn -> TempFiles.release(handle) end)
    {:ok, input} = TempFiles.path(handle, :input)
    {:ok, probe} = TempFiles.path(handle, :probe)
    {:ok, decoded} = TempFiles.path(handle, :decoded)
    fixture = Application.app_dir(:backplane_llama, "priv/audio/readiness/flac-flac.flac")
    File.cp!(fixture, input)

    probe_command = %{
      mode: :probe,
      args: [
        "-v",
        "error",
        "-protocol_whitelist",
        "file,pipe",
        "-f",
        "flac",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        "-o",
        probe,
        "-i",
        input
      ],
      output: probe,
      max_bytes: 1_000_000
    }

    assert_run(handle, probe_command, policy)
    assert %{"streams" => [%{"codec_name" => "flac"}]} = Jason.decode!(File.read!(probe))

    decode_command = %{
      mode: :convert,
      args: [
        "-nostdin",
        "-hide_banner",
        "-v",
        "error",
        "-threads",
        "1",
        "-filter_threads",
        "1",
        "-xerror",
        "-err_detect",
        "explode",
        "-protocol_whitelist",
        "file,pipe",
        "-f",
        "flac",
        "-i",
        input,
        "-map",
        "0:a:0",
        "-vn",
        "-sn",
        "-dn",
        "-c:a",
        "pcm_s16le",
        "-f",
        "s16le",
        decoded
      ],
      output: decoded,
      max_bytes: 1_000_000
    }

    assert_run(handle, decode_command, policy)
    assert %{size: size} = File.stat!(decoded)
    assert size > 0 and rem(size, 2) == 0
    assert :ok = TempFiles.release(handle)
  end

  defp assert_run(handle, command, policy) do
    case Runner.run(handle, command, policy) do
      {:ok, path, bytes} when path == command.output and bytes > 0 ->
        :ok

      result ->
        # Only synthetic, checked-in audio reaches this diagnostic path. Keep
        # native stderr out of production errors while exposing CI startup failures.
        output_before_retry = File.stat(command.output)
        File.rm(command.output)
        frames = launcher_frames(handle, command, policy)

        flunk(
          "Runner failed: #{inspect(result)}; output: #{inspect(output_before_retry)}; " <>
            "native frames: #{inspect(frames)}"
        )
    end
  end

  defp launcher_frames(handle, command, policy) do
    deadline =
      if command.mode == :probe,
        do: policy["probe_timeout_ms"],
        else: policy["conversion_timeout_ms"]

    args =
      [
        "--mode",
        Atom.to_string(command.mode),
        "--workdir",
        handle.dir,
        "--deadline-ms",
        Integer.to_string(deadline),
        "--max-file-bytes",
        Integer.to_string(command.max_bytes),
        "--stderr-bytes",
        "4096",
        "--",
        Runner.executable(command.mode)
      ] ++ command.args

    port =
      Port.open({:spawn_executable, Runner.launcher()}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:packet, 4},
        {:args, args}
      ])

    try do
      collect_frames(port, [], System.monotonic_time(:millisecond) + deadline + 5_000)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_frames(port, frames, deadline) do
    receive do
      {^port, {:data, frame}} -> collect_frames(port, [frame | frames], deadline)
      {^port, {:exit_status, status}} -> {status, Enum.reverse(frames)}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:timeout, Enum.reverse(frames)}
    end
  end
end
