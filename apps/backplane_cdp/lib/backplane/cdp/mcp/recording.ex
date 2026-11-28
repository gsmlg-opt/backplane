defmodule Backplane.CDP.MCP.Recording do
  @moduledoc false
  alias Backplane.CDP.MCP.{Artifacts, Diagnostics, Observer, Pages, TraceInsights}

  @trace_categories "-*,devtools.timeline,disabled-by-default-devtools.timeline,blink.user_timing,loading,latencyInfo"
  @max_bytes 64 * 1024 * 1024

  def call(name, args, state) do
    with {:ok, target, state} <- Pages.selected(args, state),
         {:ok, observer, state} <- Diagnostics.ensure(target, state) do
      run(name, observer, args, state)
    end
  end

  defp run("performance_analyze_insight", _observer, args, state) do
    case Map.get(state, :last_trace) do
      nil ->
        text(
          "No recorded traces found. Record a performance trace so you have Insights to analyze.",
          state
        )

      %{page: page, sets: sets} ->
        case page == args["pageId"] && get_in(sets, [args["insightSetId"], args["insightName"]]) do
          detail when is_binary(detail) ->
            text("#{args["insightName"]}\n#{detail}", state)

          _ ->
            {:error, "Use an insight set and name listed in the latest trace for this page.",
             state}
        end
    end
  end

  defp run("screencast_start", observer, args, state) do
    if Map.has_key?(state.casts, observer) do
      text(
        "Error: a screencast recording is already in progress. Use screencast_stop to stop it before starting a new one.",
        state
      )
    else
      with {:ok, path} <- Artifacts.destination(args["filePath"], ".mp4"),
           {:ok, %{"cssVisualViewport" => viewport}} <-
             Observer.command(observer, "Page.getLayoutMetrics", %{}),
           params = %{
             "maxWidth" => ceil(viewport["clientWidth"]),
             "maxHeight" => ceil(viewport["clientHeight"])
           },
           {:ok, %{"stream" => handle}} <-
             Observer.command(observer, "Page.startScreenRecording", params) do
        text(
          "Screencast recording started. The recording will be saved to #{path}. Use screencast_stop to stop recording.",
          put_in(state.casts[observer], {handle, path})
        )
      else
        {:error, "Chrome protocol error: 'Page.startScreenRecording' wasn't found"} ->
          {:error,
           "The connected Chrome does not support screen recording. Update Chrome to a newer version.",
           state}

        {:error, msg} ->
          {:error, msg, state}

        _ ->
          {:error, "Chrome did not return a recording stream", state}
      end
    end
  end

  defp run("screencast_stop", observer, _, state) do
    case Map.pop(state.casts, observer) do
      {nil, _} ->
        text("Error: no active screencast recording to stop.", state)

      {{handle, path}, remaining} ->
        state = %{state | casts: remaining}

        try do
          with {:ok, _} <- Observer.command(observer, "Page.stopScreenRecording", %{}),
               {:ok, bytes} <- read_stream(observer, handle),
               {:ok, _} <- Artifacts.save(path, bytes) do
            text("The screencast recording has been stopped and saved to #{path}.", state)
          else
            {:error, msg} -> {:error, msg, state}
          end
        after
          Observer.command(observer, "IO.close", %{"handle" => handle})
        end
    end
  end

  defp run("performance_start_trace", _, _, %{trace: trace} = state) when not is_nil(trace),
    do:
      text(
        "Error: a performance trace is already running. Use performance_stop_trace to stop it.",
        state
      )

  defp run("performance_start_trace", observer, args, state) do
    with {:ok, path} <- trace_path(args["filePath"]),
         {:ok, _} <-
           Observer.command(observer, "Tracing.start", %{
             "transferMode" => "ReturnAsStream",
             "categories" => @trace_categories
           }) do
      state = %{state | trace: {observer, path}}
      reload = Map.get(args, "reload", true)

      case reload &&
             Observer.command(observer, "Page.reload", %{
               "ignoreCache" => Map.get(args, "ignoreCache", false)
             }) do
        {:error, msg} ->
          Observer.command(observer, "Tracing.end", %{})
          {:error, msg, %{state | trace: nil}}

        _ ->
          if Map.get(args, "autoStop", true) do
            Process.sleep(5_000)
            stop_trace(observer, path, state)
          else
            text(
              "The performance trace is being recorded. Use performance_stop_trace to stop it.",
              state
            )
          end
      end
    else
      {:error, msg} -> {:error, msg, state}
    end
  end

  defp run("performance_stop_trace", _, _, %{trace: nil} = state),
    do: text("Error: no active performance trace recording to stop.", state)

  defp run("performance_stop_trace", observer, args, %{trace: {observer, path}} = state) do
    case args["filePath"] do
      nil ->
        stop_trace(observer, path, state)

      override ->
        case trace_path(override) do
          {:ok, path} -> stop_trace(observer, path, state)
          {:error, msg} -> {:error, msg, state}
        end
    end
  end

  defp run("performance_stop_trace", _, _, state),
    do: {:error, "Use the pageId where the trace was started.", state}

  defp stop_trace(observer, path, state) do
    state = %{state | trace: nil}

    with {:ok, _} <- Observer.command(observer, "Tracing.end", %{}),
         {:ok, %{"stream" => handle}} <-
           Observer.wait_event(observer, "Tracing.tracingComplete", 15_000) do
      try do
        with {:ok, bytes} <- read_stream(observer, handle),
             {:ok, saved} <- save_trace(path, bytes),
             {:ok, %{"frameTree" => %{"frame" => %{"id" => frame}}}} <-
               Observer.command(observer, "Page.getFrameTree", %{}) do
          sets = TraceInsights.build(bytes, frame)

          {page, _} =
            Enum.find(state.pages, fn {_id, target} -> state.observers[target] == observer end)

          text(
            saved <> "\n" <> TraceInsights.summary(sets),
            Map.put(state, :last_trace, %{page: page, sets: sets})
          )
        else
          {:error, msg} -> {:error, msg, state}
        end
      after
        Observer.command(observer, "IO.close", %{"handle" => handle})
      end
    else
      {:error, msg} -> {:error, msg, state}
      _ -> {:error, "Chrome did not return a trace stream", state}
    end
  end

  defp save_trace(nil, _bytes), do: {:ok, "The performance trace has been stopped."}

  defp save_trace(path, bytes) do
    data = if String.ends_with?(path, ".gz"), do: :zlib.gzip(bytes), else: bytes

    with {:ok, _} <- Artifacts.save(path, data),
         do: {:ok, "The performance trace has been stopped and saved to #{path}."}
  end

  defp trace_path(nil), do: {:ok, nil}

  defp trace_path(path) do
    extension = if is_binary(path) and String.ends_with?(path, ".gz"), do: ".gz", else: ".json"
    Artifacts.destination(path, extension)
  end

  defp read_stream(pid, handle),
    do: read_stream(pid, handle, [], 0, System.monotonic_time(:second) + 30)

  defp read_stream(pid, handle, chunks, size, deadline) do
    with true <- System.monotonic_time(:second) < deadline,
         {:ok, %{"data" => data} = part} <-
           Observer.command(pid, "IO.read", %{"handle" => handle, "size" => 256 * 1024}),
         {:ok, bytes} <- decode(part["base64Encoded"], data),
         true <- byte_size(bytes) + size <= @max_bytes do
      chunks = [bytes | chunks]

      if part["eof"],
        do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()},
        else: read_stream(pid, handle, chunks, size + byte_size(bytes), deadline)
    else
      {:error, msg} -> {:error, msg}
      _ -> {:error, "Chrome recording exceeded its size or time limit"}
    end
  end

  defp decode(true, data), do: Base.decode64(data)
  defp decode(_, data), do: {:ok, data}
  defp text(message, state), do: {:ok, [%{"type" => "text", "text" => message}], state}
end
