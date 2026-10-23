defmodule Backplane.AgentRuntime.Plugins.Backend do
  @moduledoc "Executes an admitted plugin tool within its owning run."
  alias Backplane.AgentRuntime.{Error, Plugins.Session}

  def execute(%{
        backend_context: %{session: session},
        run_id: run_id,
        tool_name: name,
        arguments: arguments
      }) do
    case Session.call_tool(session, run_id, name, arguments) do
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Error.new(:unavailable, "plugin MCP tool is unavailable")}
    end
  catch
    :exit, _ -> {:error, Error.new(:unavailable, "plugin session is unavailable")}
  end

  def execute(_), do: {:error, Error.new(:forbidden, "plugin tool requires its owning session")}
end
