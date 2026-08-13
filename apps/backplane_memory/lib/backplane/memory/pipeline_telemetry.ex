defmodule Backplane.Memory.PipelineTelemetry do
  @moduledoc "Uniform, privacy-safe telemetry for Memory pipeline stages."

  @event [:backplane, :memory, :pipeline]
  @dimensions ~w(host_id client_id scope namespace session_id project integration source_type)

  @spec span(String.t(), map(), (-> term())) :: term()
  def span(stage, metadata, fun)
      when is_binary(stage) and is_map(metadata) and is_function(fun, 0) do
    started_at = System.monotonic_time()

    try do
      result = fun.()
      {status, error_class} = classify(result)
      emit(started_at, stage, metadata, status, error_class)
      result
    rescue
      exception ->
        emit(
          started_at,
          stage,
          metadata,
          "error",
          exception.__struct__ |> Module.split() |> List.last()
        )

        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit(started_at, stage, metadata, "error", error_class({kind, reason}))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit(started_at, stage, metadata, status, error_class) do
    duration_us =
      (System.monotonic_time() - started_at)
      |> System.convert_time_unit(:native, :microsecond)

    dimensions =
      Map.new(@dimensions, fn key ->
        {String.to_atom(key), Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))}
      end)

    :telemetry.execute(
      @event,
      %{count: 1, duration_us: duration_us},
      Map.merge(dimensions, %{stage: stage, status: status, error_class: error_class})
    )
  end

  defp classify(:ok), do: {"ok", nil}
  defp classify({:ok, _result}), do: {"ok", nil}
  defp classify({:building, _result}), do: {"ok", nil}
  defp classify({:skip, reason}), do: {"skipped", error_class(reason)}
  defp classify({:snooze, _seconds}), do: {"retry", nil}
  defp classify({:cancel, reason}), do: {"cancelled", error_class(reason)}
  defp classify({:discard, reason}), do: {"dead_letter", error_class(reason)}
  defp classify({:error, reason}), do: {"error", error_class(reason)}
  defp classify(_result), do: {"ok", nil}

  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(%module{}) when is_atom(module), do: module |> Module.split() |> List.last()
  defp error_class(_reason), do: "unknown"
end
