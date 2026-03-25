defmodule Backplane.Telemetry do
  @moduledoc """
  Telemetry event definitions and helpers for Backplane.

  Events:
    - [:backplane, :tool_call, :start]
    - [:backplane, :tool_call, :stop]
    - [:backplane, :tool_call, :exception]
  """

  @doc "Execute a tool call with telemetry instrumentation."
  def span_tool_call(tool_name, fun) do
    metadata = %{tool: tool_name}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:backplane, :tool_call, :start],
      %{system_time: System.system_time()},
      metadata
    )

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      result_status =
        case result do
          {:ok, _} -> :ok
          {:error, _} -> :error
          _ -> :ok
        end

      :telemetry.execute(
        [:backplane, :tool_call, :stop],
        %{duration: duration},
        Map.put(metadata, :result, result_status)
      )

      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:backplane, :tool_call, :exception],
          %{duration: duration},
          Map.merge(metadata, %{kind: :error, reason: e})
        )

        reraise e, __STACKTRACE__
    end
  end
end
