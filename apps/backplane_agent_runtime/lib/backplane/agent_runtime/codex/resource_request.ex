defmodule Backplane.AgentRuntime.Codex.ResourceRequest do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.McpProtocol.Client

  def run(%{backend_context: %{runtime: runtime} = context} = operation, starter)
      when is_pid(runtime) and is_function(starter, 0) do
    control = Client.resource_cancellation_control()

    with {:ok, registration} <- GenServer.call(runtime, {:register_resource, operation, control}) do
      run_registered(runtime, context, operation, registration, control, starter)
    end
  end

  def run(_, _),
    do: {:error, Error.new(:validation, "resource request requires a native operation")}

  defp run_registered(runtime, context, operation, registration, control, starter) do
    with :ok <- register_conversation(context, operation, registration),
         result <- starter.() do
      result =
        case result do
          {:ok, handle} ->
            {:ok, identity} = Client.resource_request_identity(handle)
            :ok = GenServer.call(runtime, {:attach_resource, registration, identity})
            Client.await_resource_request(handle, :infinity, cancellation: control)

          error ->
            error
        end

      :ok = GenServer.call(runtime, {:finish_resource, registration, result})

      case result do
        {:cancelled, _report} -> {:error, Error.new(:cancelled, "MCP resource request cancelled")}
        other -> other
      end
    else
      error ->
        GenServer.call(runtime, {:discard_resource, registration})
        error
    end
  end

  def cancel(operation) do
    runtime = operation.backend_context.runtime
    deadline = Map.fetch!(operation, :cleanup_deadline)
    timeout = max(1, deadline - System.monotonic_time(:millisecond))
    GenServer.call(runtime, {:cancel_resource, operation, deadline}, timeout)
  catch
    :exit, _ ->
      {:error, Error.new(:unknown_outcome, "MCP cancellation acknowledgement unavailable")}
  end

  defp register_conversation(context, operation, registration) do
    case context[:register_cancellation] do
      register when is_function(register, 2) ->
        case register.(operation, registration) do
          {:ok, coordinator} when is_pid(coordinator) ->
            GenServer.call(context.runtime, {:coordinate_resource, registration, coordinator})

          other ->
            other
        end

      nil ->
        :ok

      _ ->
        {:error, Error.new(:validation, "resource cancellation context is invalid")}
    end
  end

  def assertion(entry, report) do
    identity = entry.request_identity

    if is_map(identity) and
         Enum.all?([:logical_id, :client_incarnation, :method], fn key ->
           Map.fetch(report, key) === Map.fetch(identity, key)
         end) do
      ToolEffects.confirm_cancellation(
        entry.operation
        |> Map.put(:stop_generation, entry.stop_generation)
        |> Map.put(:resource_registration, entry.registration),
        report
        |> Map.put(:registration_id, entry.registration)
        |> Map.put(:stop_generation, entry.stop_generation)
      )
    else
      {:error, Error.new(:unknown_outcome, "MCP cancellation request identity mismatch")}
    end
  end

  def release(%{operation: operation, registration: registration}) do
    GenServer.cast(
      operation.backend_context.runtime,
      {:release_resource, registration, ToolEffects.cancellation_identity(operation)}
    )
  end

  def registration_id, do: "resource_#{System.unique_integer([:positive, :monotonic])}"

  def signal(control, reason, deadline) do
    Client.cancel_resource_wait(control, reason,
      timeout: max(1, deadline - System.monotonic_time(:millisecond))
    )
  end
end
