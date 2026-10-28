defmodule Backplane.AgentRuntime.Codex.PluginInstallWait do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence

  def run(%{backend_context: %{runtime: runtime} = context} = operation, reference, wait_fn)
      when is_pid(runtime) and is_binary(reference) and byte_size(reference) in 1..4_096 and
             is_function(wait_fn, 0) do
    with true <- String.valid?(reference),
         {:ok, registration} <-
           GenServer.call(runtime, {:register_plugin_wait, operation, reference}),
         register when is_function(register, 2) <- context[:register_cancellation],
         {:ok, coordinator} when is_pid(coordinator) <- register.(operation, registration),
         :ok <- GenServer.call(runtime, {:coordinate_plugin_wait, registration, coordinator}) do
      wait_fn.()
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> unavailable()
    end
  end

  def run(_, _, _), do: {:error, Error.new(:validation, "plugin observation wait is invalid")}

  def cancel(operation) do
    deadline = Map.fetch!(operation, :cleanup_deadline)

    GenServer.call(
      operation.backend_context.runtime,
      {:cancel_plugin_wait, operation, deadline},
      max(1, deadline - System.monotonic_time(:millisecond))
    )
  catch
    :exit, _ -> unavailable()
  end

  def release(%{operation: operation, registration: registration}) do
    GenServer.cast(
      operation.backend_context.runtime,
      {:release_plugin_wait, registration, ToolEffects.cancellation_identity(operation)}
    )
  end

  def proof(entry, runtime_id) do
    {:ok, public} =
      Evidence.public(%{
        schema_version: 1,
        record_type: :native_plugin_wait_retirement,
        identity: ToolEffects.cancellation_identity(entry.operation),
        plugin_request_id: entry.operation.plugin_request_id,
        host_request_ref: entry.host_request_ref,
        registration_id: entry.registration,
        stop_generation: entry.stop_generation,
        provenance: %{
          runtime_id: runtime_id,
          session_binding_identity: entry.operation[:session_binding_identity]
        },
        completion_gate: :closed,
        waiter_down: true,
        local_cleanup: :confirmed,
        outcome: :unknown
      })

    Evidence.seal(public, "retirement_digest")
  end

  def unavailable,
    do: {:error, Error.new(:unknown_outcome, "plugin wait retirement is unavailable")}
end
