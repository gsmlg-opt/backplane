defmodule Backplane.Memory.EdgeSync.Store do
  @moduledoc "Durable storage boundary for the stateless host memory protocol."
  @callback negotiate(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback next(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback ack(String.t(), map()) :: {:ok, map()} | {:error, term()}
end
