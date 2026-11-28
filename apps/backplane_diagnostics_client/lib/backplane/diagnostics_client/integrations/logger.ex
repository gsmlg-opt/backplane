defmodule Backplane.DiagnosticsClient.Integrations.Logger do
  @moduledoc "OTP Logger handler for structured crash reports and ordinary error metadata."

  alias Backplane.DiagnosticsClient.Integrations.Capture

  def attach(id \\ __MODULE__, opts \\ []) do
    :logger.add_handler(id, __MODULE__, %{level: :error, config: opts})
  end

  def detach(id \\ __MODULE__), do: :logger.remove_handler(id)

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok

  def log(%{meta: metadata}, %{config: opts}) do
    unless Capture.reporting?() or Capture.internal_module?(metadata[:mfa]) or
             metadata[:diagnostics_origin] == true do
      opts = Keyword.merge(opts, pid: metadata[:pid], request_id: metadata[:request_id])

      case metadata[:crash_reason] do
        {reason, frames} when is_list(frames) ->
          Capture.report("exception", :error, reason, frames, opts)

        _ ->
          Capture.report(
            "log_error",
            :logger_error,
            :unavailable,
            [],
            Keyword.put(opts, :error_class, "unknown")
          )
      end
    end

    :ok
  end

  def log(_, _), do: :ok
end
