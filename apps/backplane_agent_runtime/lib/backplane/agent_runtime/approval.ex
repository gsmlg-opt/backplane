defmodule Backplane.AgentRuntime.Approval do
  @moduledoc """
  Approval contracts for Backplane agent runtime.

  A decision must bind the approval identity, resolver identity, exact tool,
  arguments digest, and tool revision. The model cannot self-approve.
  """

  @spec decide(map(), map()) ::
          {:ok, :approved | :denied} | {:error, Backplane.AgentRuntime.Error.t()}
  def decide(approval, decision) when is_map(approval) and is_map(decision) do
    with {:ok, _} <- validate_decision(decision),
         {:ok, _} <- validate_identity(approval, decision),
         {:ok, _} <- validate_operation(approval, decision),
         {:ok, _} <- reject_self_approval(approval, decision),
         {:ok, _} <- validate_expiry(approval) do
      {:ok, Map.get(decision, :decision) || Map.get(decision, "decision")}
    else
      {:error, %Backplane.AgentRuntime.Error{} = error} ->
        {:error, error}
    end
  end

  def decide(approval, decision) do
    {:error,
     Backplane.AgentRuntime.Error.new(:validation, "invalid approval or decision",
       details: %{approval: approval, decision: decision}
     )}
  end

  defp validate_operation(approval, decision) do
    with {:ok, tool_name} <- operation_field(approval, decision, :tool_name, "tool name"),
         {:ok, tool_revision} <-
           operation_field(approval, decision, :tool_revision, "tool revision"),
         {:ok, arguments_digest} <-
           operation_field(approval, decision, :arguments_digest, "arguments digest") do
      if is_integer(tool_revision) and is_binary(arguments_digest) do
        {:ok, tool_name}
      else
        {:error,
         Backplane.AgentRuntime.Error.new(:forbidden, "approval operation revision is invalid")}
      end
    end
  end

  defp operation_field(approval, decision, key, label) do
    approval_value = Map.get(approval, key)
    decision_value = Map.get(decision, key)

    if approval_value != nil and approval_value == decision_value do
      {:ok, approval_value}
    else
      {:error, Backplane.AgentRuntime.Error.new(:forbidden, "approval #{label} does not match")}
    end
  end

  defp reject_self_approval(approval, decision) do
    run_id = Map.get(approval, :run_id)
    resolver_id = Map.get(decision, :resolver_id)

    if is_binary(run_id) and is_binary(resolver_id) and resolver_id == run_id do
      {:error, Backplane.AgentRuntime.Error.new(:forbidden, "model cannot self-approve")}
    else
      {:ok, resolver_id}
    end
  end

  defp validate_identity(approval, decision) do
    approval_id = Map.get(approval, :approval_id) || Map.get(approval, "approval_id")
    decision_approval_id = Map.get(decision, :approval_id) || Map.get(decision, "approval_id")

    if is_binary(approval_id) and decision_approval_id == approval_id do
      {:ok, approval_id}
    else
      {:error, Backplane.AgentRuntime.Error.new(:forbidden, "approval identity does not match")}
    end
  end

  defp validate_decision(decision) do
    value = Map.get(decision, :decision) || Map.get(decision, "decision")

    if value in [:approved, :denied] do
      {:ok, value}
    else
      {:error,
       Backplane.AgentRuntime.Error.new(:validation, "decision must be :approved or :denied")}
    end
  end

  defp validate_expiry(approval) do
    now = Map.get(approval, :current_time) || Map.get(approval, "current_time")
    expires_at = Map.get(approval, :expires_at) || Map.get(approval, "expires_at")

    if is_integer(now) and is_integer(expires_at) and now <= expires_at do
      {:ok, expires_at}
    else
      {:error, Backplane.AgentRuntime.Error.new(:validation, "approval is expired")}
    end
  end
end
