defmodule BackplaneTelemetry.TelemetryCapture do
  @moduledoc false

  import ExUnit.Assertions

  @doc """
  Attaches a synchronous telemetry handler that sends captured events to `owner`.

  Accepts either one event name `[:a, :b]` or a list of event names
  `[[:a, :b], [:a, :c]]`. Always detach in `on_exit`.
  """
  @spec attach(pid(), :telemetry.event_name() | [:telemetry.event_name()]) :: String.t()
  def attach(owner, event_or_events) when is_pid(owner) do
    handler_id = "telemetry-capture-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        normalize_events(event_or_events),
        fn event, measurements, metadata, _config ->
          send(owner, {:telemetry_capture, event, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  @doc "Detaches a handler previously returned by `attach/2`."
  @spec detach(String.t()) :: :ok
  def detach(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
  end

  @doc """
  Asserts that a captured telemetry message arrives.

  Returns `{measurements, metadata}`.
  """
  @spec assert_event(:telemetry.event_name(), non_neg_integer()) :: {map(), map()}
  def assert_event(event, timeout \\ 100) do
    receive do
      {:telemetry_capture, ^event, measurements, metadata} ->
        {measurements, metadata}
    after
      timeout ->
        flunk("expected telemetry event #{inspect(event)} within #{timeout}ms")
    end
  end

  defp normalize_events([[_ | _] | _] = events), do: events
  defp normalize_events([atom | _] = event) when is_atom(atom), do: [event]
end
