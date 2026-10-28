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
      operation =
        Map.put(
          operation,
          :session_binding_identity,
          Map.take(binding, [:run_id, :owner_id, :incarnation, :run_incarnation])
        )

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
      |> Map.put(:runtime_operation, operation)

    Tools.call(context, operation.tool_name, operation.arguments)
  end

  def execute(%{backend_context: %{family: :service, context: context} = backend} = operation) do
    runtime_context = %{
      identity:
        Map.take(operation, [
          :run_id,
          :incarnation,
          :turn_id,
          :step_id,
          :attempt_id,
          :invocation_id,
          :tool_name,
          :tool_revision,
          :catalog_revision,
          :tool_call_id,
          :enclosing_invocation_id,
          :session_binding_identity
        ]),
      resource_owner: Map.get(backend, :resource_owner),
      resource_owner_pid: Map.get(backend, :resource_owner_pid),
      effect_owner_pid: self(),
      effect_deadline: Map.get(backend, :effect_deadline)
    }

    Services.call(
      Map.put(context, :runtime_context, runtime_context),
      operation.tool_name,
      operation.arguments
    )
  end

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

  def cancel(
        %{tool_name: "request_plugin_install", backend_context: %{family: :dynamic}} = operation
      ),
      do: Backplane.AgentRuntime.Codex.PluginInstallWait.cancel(operation)

  def cancel(%{backend_context: %{family: :dynamic}} = operation),
    do: DynamicRuntime.cancel_resource(operation)

  def cancel(_),
    do: {:error, Error.new(:unsupported_capability, "tool has no verified cancellation contract")}
end
