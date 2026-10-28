defmodule Backplane.McpProtocol.Client.ResourceRetirement do
  @moduledoc false

  alias Backplane.McpProtocol.Client.TrackedRetirement

  # State owns ordinary terminal removal; both supported families use one ledger.
  defdelegate terminal(state, request), to: TrackedRetirement
end
