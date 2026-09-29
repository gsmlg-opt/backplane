defmodule Backplane.AgentRuntime.Codex.Backend do
  @moduledoc false

  alias Backplane.AgentRuntime.{
    Codex.CodeMode,
    Codex.Control,
    Codex.DynamicRuntime,
    Codex.ExtensionRuntime,
    Codex.MultiAgent,
    Codex.Services,
    Codex.Tools,
    Error
  }

  def execute(%{backend_context: %{family: :local, context: context}} = operation),
    do: Tools.call(context, operation.tool_name, operation.arguments)

  def execute(%{backend_context: %{family: :service, context: context}} = operation),
    do: Services.call(context, operation.tool_name, operation.arguments)

  def execute(%{backend_context: %{family: :control}} = operation), do: Control.call(operation)

  def execute(%{backend_context: %{family: :collaboration}} = operation),
    do: MultiAgent.call(operation)

  def execute(%{backend_context: %{family: :code_mode}} = operation), do: CodeMode.call(operation)

  def execute(%{backend_context: %{family: :dynamic}} = operation),
    do: DynamicRuntime.call(operation)

  def execute(%{backend_context: %{family: :extensions}} = operation),
    do: ExtensionRuntime.call(operation)

  def execute(_operation),
    do: {:error, Error.new(:unsupported_capability, "Codex backend context is unavailable")}
end
