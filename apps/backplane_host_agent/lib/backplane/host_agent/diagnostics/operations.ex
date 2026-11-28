defmodule Backplane.HostAgent.Diagnostics.Operations do
  @moduledoc "Trusted Host release commands for inspecting, reoffering and closing diagnostics delivery."

  alias Backplane.DiagnosticsClient.Envelope
  alias Backplane.HostAgent.{Channel, MemoryProxy}
  alias Backplane.HostAgent.Diagnostics.Spool

  def dead_letters(source_id) do
    if Envelope.id?(source_id),
      do: Spool.dead_letters(Spool, source_id),
      else: {:error, :invalid_source}
  end

  def requeue(source_id, event_id) do
    if Envelope.id?(source_id) and Envelope.id?(event_id),
      do: Spool.requeue(Spool, source_id, event_id),
      else: {:error, :invalid_event}
  end

  @doc "Closes an operator-confirmed retired epoch after its pending records have settled."
  def seal_epoch(source_id, epoch) do
    with true <- Envelope.id?(source_id) and Envelope.id?(epoch),
         {:ok, :ok} <- Spool.seal_epoch(Spool, source_id, epoch),
         channel when is_pid(channel) <- MemoryProxy.channel() do
      Channel.push(channel, "diagnostics_seal_epoch", %{
        "source_id" => source_id,
        "producer_epoch" => epoch
      })
    else
      false -> {:error, :invalid_epoch}
      nil -> {:error, :gateway_unavailable}
      error -> error
    end
  end
end
