defmodule Backplane.LLM.UsageCollector do
  @moduledoc """
  Telemetry handler that listens for [:backplane, :llm, :request] events
  and enqueues an Oban UsageWriter job to persist the usage data.

  Call `attach/0` during application startup to activate the handler.
  """

  @handler_id "backplane-llm-usage-collector"

  @doc "Attach this handler to the [:backplane, :llm, :request] telemetry event."
  def attach do
    :telemetry.attach(
      @handler_id,
      [:backplane, :llm, :request],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc "Detach this handler (useful for testing cleanup)."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event([:backplane, :llm, :request], measurements, metadata, _config) do
    args = %{
      "provider_id" => metadata.provider_id,
      "model" => metadata.model,
      "status" => metadata.status,
      "latency_ms" => measurements.latency_ms,
      "input_tokens" => metadata[:input_tokens],
      "output_tokens" => metadata[:output_tokens],
      "stream" => metadata[:stream] || false,
      "client_ip" => metadata[:client_ip],
      "error_reason" => metadata[:error_reason]
    }

    Backplane.Jobs.UsageWriter.new(args) |> Oban.insert()
  end
end
