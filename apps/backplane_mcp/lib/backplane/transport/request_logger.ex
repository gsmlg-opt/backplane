defmodule Backplane.Transport.RequestLogger do
  @moduledoc """
  Deprecated alias for `Backplane.Transport.McpObservability`.

  Kept for backward-compatible plug references and tests.
  """

  defdelegate init(opts), to: Backplane.Transport.McpObservability
  defdelegate call(conn, opts), to: Backplane.Transport.McpObservability
end
