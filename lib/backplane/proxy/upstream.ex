defmodule Backplane.Proxy.Upstream do
  @moduledoc """
  GenServer managing a single upstream MCP server connection.
  Placeholder for Phase 2 implementation.
  """

  def forward(_upstream_pid, _tool_name, _args) do
    {:error, "Upstream proxy not yet implemented"}
  end
end
