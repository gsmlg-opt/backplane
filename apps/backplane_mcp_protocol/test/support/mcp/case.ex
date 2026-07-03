defmodule Backplane.McpProtocol.MCP.Case do
  @moduledoc """
  Test case template for MCP protocol testing.

  Provides a consistent setup and common imports for MCP tests.
  """

  use ExUnit.CaseTemplate

  using opts do
    async = Keyword.get(opts, :async, false)

    quote do
      use ExUnit.Case, async: unquote(async)

      import Backplane.McpProtocol.MCP.Assertions
      import Backplane.McpProtocol.MCP.Builders
      import Backplane.McpProtocol.MCP.Setup

      require Backplane.McpProtocol.MCP.Message

      @moduletag capture_log: true
    end
  end
end
