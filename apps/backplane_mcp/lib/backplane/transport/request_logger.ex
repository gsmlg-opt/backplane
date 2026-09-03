defmodule Backplane.Transport.RequestLogger do
  @moduledoc """
  Compatibility plug that delegates to `Backplane.Transport.McpObservability`.

  Legacy callers and tests may still reference this module; observability v2
  behavior lives in `McpObservability`.
  """

  defdelegate init(opts), to: Backplane.Transport.McpObservability
  defdelegate call(conn, opts), to: Backplane.Transport.McpObservability
end
