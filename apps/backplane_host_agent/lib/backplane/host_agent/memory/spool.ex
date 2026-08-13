defmodule Backplane.HostAgent.Memory.Spool do
  @moduledoc "Behaviour for a durable host-capture delivery spool."

  alias Backplane.HostAgent.Memory.EventEnvelope

  @type server :: GenServer.server()
  @type event_id :: String.t()

  @callback append(server(), map() | EventEnvelope.t()) ::
              {:ok, EventEnvelope.t()} | {:duplicate, EventEnvelope.t()} | {:error, term()}
  @callback next_batch(server(), pos_integer(), pos_integer()) ::
              [EventEnvelope.t()] | {:oversized, EventEnvelope.t()} | {:error, term()}
  @callback acknowledge(server(), [event_id()]) :: :ok | {:error, term()}
  @callback reject(server(), event_id(), term(), boolean()) :: :ok | {:error, term()}
  @callback stats(server()) :: map() | {:error, term()}
end
