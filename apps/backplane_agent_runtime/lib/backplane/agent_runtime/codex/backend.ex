defmodule Backplane.AgentRuntime.Codex.Backend do
  @moduledoc false

  alias Backplane.AgentRuntime.{
    Codex.CodeMode,
    Codex.Control,
    Codex.DynamicRuntime,
    Codex.ExtensionRuntime,
    Codex.MultiAgent,
    Codex.Services,
    Codex.Session,
    Codex.Tools,
    Error
  }

  def execute(%{backend_context: %{session_binding: binding} = backend} = operation) do
    with {:ok, owner} <- Session.validate(binding, operation) do
      operation = %{
        operation
        | backend_context:
            backend
            |> Map.delete(:session_binding)
            |> Map.put(:resource_owner, owner)
            |> Map.put(:resource_owner_pid, owner.owner_pid)
      }

      execute(operation)
    end
  end

  def execute(
        %{backend_context: %{family: :local, context: context} = backend_context} = operation
      ) do
    context =
      case Map.get(backend_context, :resource_owner_pid) do
        pid when is_pid(pid) -> Map.put(context, :owner_pid, pid)
        _ -> context
      end
      |> Map.put(:incarnation, Map.get(operation, :incarnation, 1))
      |> Map.put(:resource_owner, Map.get(backend_context, :resource_owner))

    Tools.call(context, operation.tool_name, operation.arguments)
  end

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
