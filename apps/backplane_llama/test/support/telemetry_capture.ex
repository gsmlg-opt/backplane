defmodule Backplane.LLM.TelemetryCapture do
  @moduledoc false

  @doc """
  Attaches a synchronous telemetry handler that sends captured events to `owner`.

  `events` must be a list of event names, for example:

      [[:backplane, :llm, :request]]

  Local to `:backplane_llama` tests. Do not depend on other apps' test support.
  """
  @spec attach(pid(), [:telemetry.event_name()]) :: String.t()
  def attach(owner, events) when is_pid(owner) and is_list(events) do
    handler_id = "llm-telemetry-capture-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        normalize_events(events),
        fn event, measurements, metadata, _config ->
          send(owner, {:telemetry_capture, event, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  @spec detach(String.t()) :: :ok
  def detach(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
  end

  defp normalize_events([[_ | _] | _] = events), do: events
  defp normalize_events([atom | _] = event) when is_atom(atom), do: [event]
end
