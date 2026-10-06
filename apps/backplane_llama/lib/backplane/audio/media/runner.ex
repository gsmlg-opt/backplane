defmodule Backplane.Audio.Media.Runner do
  @moduledoc "Bounded file-backed FFprobe and FFmpeg execution through the audio launcher."

  alias Backplane.Audio.Error
  alias Backplane.Audio.Media.{Admission, TempFiles}

  @diag_bytes 4_096
  @cleanup_wait_ms 5_000

  def executable(:probe),
    do: System.get_env("BACKPLANE_AUDIO_FFPROBE_PATH") || System.find_executable("ffprobe")

  def executable(:convert),
    do: System.get_env("BACKPLANE_AUDIO_FFMPEG_PATH") || System.find_executable("ffmpeg")

  def executable(:selftest), do: executable(:convert)

  def launcher do
    System.get_env("BACKPLANE_AUDIO_LAUNCHER_PATH") ||
      case :code.priv_dir(:backplane_llama) do
        path when is_list(path) -> Path.join(List.to_string(path), "bin/backplane-audio-launcher")
        _ -> nil
      end
  end

  def ready? do
    Enum.all?([launcher(), executable(:probe), executable(:convert)], fn path ->
      is_binary(path) and Path.type(path) == :absolute and File.regular?(path)
    end)
  end

  # The caller owns the returned file until its Media.Session releases the handle.
  # `command` contains only server-built arguments and a server-generated output path.
  def run(
        handle,
        %{mode: mode, args: args, output: output, max_bytes: _max_bytes} = command,
        policy
      )
      when mode in [:probe, :convert, :selftest] and is_list(args) and
             (is_binary(output) or is_nil(output)) do
    with {:ok, lease} <- Admission.acquire(:media, self(), policy) do
      result =
        case TempFiles.pin(handle) do
          :ok ->
            Admission.pin(lease, handle.dir)
            result = run_with_lease(handle, command, policy)
            unless cleanup_uncertain?(result), do: TempFiles.unpin(handle)
            result

          error ->
            error
        end

      if cleanup_uncertain?(result),
        do: Admission.quarantine(lease),
        else: Admission.release(lease)

      result
    end
  end

  def selftest(handle, policy),
    do: run(handle, %{mode: :selftest, args: [], output: nil, max_bytes: 1_000_000}, policy)

  defp run_with_lease(handle, command, policy) do
    binary = executable(command.mode)
    launcher = launcher()

    cond do
      not valid_executable?(binary) or not valid_executable?(launcher) ->
        {:error, Error.new(503, "Audio media tools are unavailable", nil, "audio_unavailable")}

      command.output && not String.starts_with?(Path.expand(command.output), handle.dir <> "/") ->
        {:error, Error.new(500, "Invalid media output", nil, "audio_internal_error")}

      true ->
        deadline =
          if command.mode in [:probe, :selftest],
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
            Integer.to_string(@diag_bytes),
            "--",
            binary
          ] ++ command.args

        port =
          Port.open({:spawn_executable, launcher}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:packet, 4},
            {:args, args}
          ])

        port_ref = :erlang.monitor(:port, port)

        try do
          result =
            wait(
              port,
              command.output,
              command.max_bytes,
              now() + deadline + @cleanup_wait_ms,
              nil
            )

          finish_port(port, port_ref, result)
        rescue
          _ -> finish_port(port, port_ref, cancel_and_confirm(port))
        catch
          _, _ -> finish_port(port, port_ref, cancel_and_confirm(port))
        after
          close_port(port)
          :erlang.demonitor(port_ref, [:flush])
          flush_port_messages(port)
        end
    end
  rescue
    _ -> {:error, Error.new(503, "Audio media tools are unavailable", nil, "audio_unavailable")}
  end

  defp wait(port, output, max_bytes, timeout, advisory) do
    owner_ref = Process.get(:audio_owner_monitor)

    receive do
      {^port, {:data, <<?S, _pid::32, _pgid::32>>}} ->
        wait(port, output, max_bytes, timeout, advisory)

      {^port, {:data, <<?D, _bounded_diagnostic::binary>>}} ->
        wait(port, output, max_bytes, timeout, advisory)

      {^port, {:data, <<?E, reason::binary>>}} ->
        wait(port, output, max_bytes, timeout, safe_reason(reason))

      {^port, {:data, <<?X, exit_code::32, signal::8, 1::8>>}} ->
        advisory = if signal != 0 and is_nil(advisory), do: "media_failed", else: advisory

        if exit_code == 0 and advisory == nil and is_nil(output) do
          {:ok, :ready}
        else
          result_file(exit_code, advisory, output, max_bytes)
        end

      {^port, {:data, <<?X, _exit_code::32, _signal::8, 0::8>>}} ->
        {:error,
         Error.new(503, "Audio media cleanup is uncertain", nil, "audio_cleanup_uncertain")}

      {^port, {:exit_status, _status}} ->
        {:error,
         Error.new(503, "Audio media cleanup is uncertain", nil, "audio_cleanup_uncertain")}

      :cancel ->
        cancel_and_confirm(port, "cancelled")

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        cancel_and_confirm(port, "cancelled")
    after
      max(timeout - now(), 0) ->
        cancel_and_confirm(port, "timeout")
    end
  end

  # X proves media cleanup, but the launcher still has to exit. Consume its
  # remaining port signals before returning to callers such as a LiveView.
  defp finish_port(port, ref, result) do
    case await_port_exit(port, ref, now() + @cleanup_wait_ms) do
      :ok ->
        result

      :timeout ->
        close_port(port)
        await_port_exit(port, ref, now() + @cleanup_wait_ms)
        {:error, media_error("cleanup_uncertain")}
    end
  end

  defp await_port_exit(port, ref, deadline) do
    receive do
      {^port, _message} -> await_port_exit(port, ref, deadline)
      {:EXIT, ^port, _reason} -> await_port_exit(port, ref, deadline)
      {:DOWN, ^ref, :port, ^port, _reason} -> :ok
    after
      max(deadline - now(), 0) -> :timeout
    end
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _message} -> flush_port_messages(port)
      {:EXIT, ^port, _reason} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp result_file(exit_code, advisory, output, max_bytes) do
    if exit_code == 0 and advisory == nil do
      case File.lstat(output) do
        {:ok, %{type: :regular, size: size}} when size > 0 and size <= max_bytes ->
          {:ok, output, size}

        _ ->
          {:error,
           Error.new(502, "Audio conversion produced invalid output", nil, "audio_media_failed")}
      end
    else
      {:error, media_error(advisory || "media_failed")}
    end
  end

  defp wait_cancel(port, deadline, reason) do
    receive do
      {^port, {:data, <<?X, _code::32, _signal::8, 1::8>>}} ->
        {:error, media_error(reason)}

      {^port, {:data, <<?X, _code::32, _signal::8, 0::8>>}} ->
        {:error, media_error("cleanup_uncertain")}

      {^port, {:exit_status, _}} ->
        {:error, media_error("cleanup_uncertain")}

      {^port, {:data, _}} ->
        wait_cancel(port, deadline, reason)
    after
      max(deadline - now(), 0) -> {:error, media_error("cleanup_uncertain")}
    end
  end

  defp valid_executable?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.regular?(path)

  defp safe_reason(reason)
       when reason in ~w(timeout cancelled sandbox_unavailable spawn_failed output_limit resource_limit cleanup_uncertain),
       do: reason

  defp safe_reason(_), do: "media_failed"

  defp media_error("cancelled"),
    do: Error.new(499, "Audio media processing was cancelled", nil, "audio_cancelled")

  defp media_error("resource_limit"),
    do: Error.new(503, "Audio media resources are exhausted", nil, "audio_resource_limit")

  defp media_error("spawn_failed"),
    do: Error.new(503, "Audio media tools are unavailable", nil, "audio_unavailable")

  defp media_error("timeout"),
    do: Error.new(504, "Audio media processing timed out", nil, "audio_media_timeout")

  defp media_error("output_limit"),
    do: Error.new(413, "Audio media output is too large", nil, "audio_output_too_large")

  defp media_error("sandbox_unavailable"),
    do: Error.new(503, "Audio media sandbox is unavailable", nil, "audio_unavailable")

  defp media_error("cleanup_uncertain"),
    do: Error.new(503, "Audio media cleanup is uncertain", nil, "audio_cleanup_uncertain")

  defp media_error(_),
    do: Error.new(502, "Audio media processing failed", nil, "audio_media_failed")

  defp cleanup_uncertain?({:error, %Error{code: "audio_cleanup_uncertain"}}), do: true
  defp cleanup_uncertain?(_), do: false

  defp cancel_and_confirm(port, reason \\ "cancelled") do
    Port.command(port, "C")
    wait_cancel(port, now() + @cleanup_wait_ms, reason)
  rescue
    _ -> {:error, media_error("cleanup_uncertain")}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
