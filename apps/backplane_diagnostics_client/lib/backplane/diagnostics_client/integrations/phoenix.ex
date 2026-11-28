defmodule Backplane.DiagnosticsClient.Integrations.Phoenix do
  @moduledoc "Captures Phoenix exception telemetry with request correlation and bounded stacks."

  alias Backplane.DiagnosticsClient.Integrations.Capture

  @events [[:phoenix, :router_dispatch, :exception], [:phoenix, :error_rendered]]

  def attach(id \\ __MODULE__, opts \\ []),
    do: :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, opts)

  def detach(id \\ __MODULE__), do: :telemetry.detach(id)

  def handle_event(
        _event,
        measurements,
        %{kind: kind, reason: reason, stacktrace: frames} = metadata,
        opts
      )
      when is_list(frames) do
    {kind, reason, frames, conn} = unwrap(kind, reason, frames, metadata[:conn])
    request_id = header_request_id(conn) || Logger.metadata()[:request_id]
    duration = measurements[:duration]

    duration_us =
      if is_integer(duration), do: System.convert_time_unit(duration, :native, :microsecond)

    Capture.report(
      "exception",
      kind,
      reason,
      frames,
      Keyword.merge(opts,
        request_id: request_id,
        duration_us: duration_us,
        phase: "phoenix_request"
      )
    )

    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  defp unwrap(
         _kind,
         %{
           __struct__: Plug.Conn.WrapperError,
           kind: kind,
           reason: reason,
           stack: stack,
           conn: conn
         },
         _frames,
         _conn
       )
       when is_list(stack),
       do: {kind, reason, stack, conn}

  defp unwrap(kind, reason, frames, conn), do: {kind, reason, frames, conn}

  defp header_request_id(%{resp_headers: headers}) do
    Enum.find_value(headers, fn
      {"x-request-id", id} -> id
      _ -> nil
    end)
  end

  defp header_request_id(_), do: nil
end
