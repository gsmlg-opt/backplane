defmodule Backplane.AgentRuntime.Policy do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Runtime policy enforcement for Backplane agent runtime.

  Validates caller, role, resource, task, tool, and approval authority.
  """

  @type authority :: %{
          required(String.t() | atom()) => term()
        }

  @spec authorize_tool(map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def authorize_tool(authority, descriptor, invocation)
      when is_map(authority) and is_map(descriptor) and is_map(invocation) do
    with {:ok, _} <- validate_tool(descriptor),
         {:ok, caller} <- validate_caller(authority, invocation),
         {:ok, _} <- validate_grant(authority, descriptor, invocation) do
      {:ok, %{status: :authorized, caller: caller, descriptor: descriptor}}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_tool(%{tool_revision: revision} = descriptor)
       when is_integer(revision) and revision > 0 do
    {:ok, descriptor}
  end

  defp validate_tool(descriptor) do
    {:error, Error.new(:validation, "invalid tool descriptor", details: %{received: descriptor})}
  end

  defp validate_caller(authority, invocation) do
    caller = Map.get(authority, :caller)
    invocation_run = Map.get(invocation, :run_id)
    authority_run = Map.get(authority, :run_id)

    if is_binary(caller) and caller != "" and is_binary(authority_run) and
         invocation_run == authority_run do
      {:ok, caller}
    else
      {:error, Error.new(:forbidden, "caller is required")}
    end
  end

  defp validate_grant(authority, descriptor, invocation) do
    grants = Map.get(authority, :grants, [])
    tool_name = Map.get(descriptor, :tool_name) || Map.get(descriptor, "tool_name")
    invocation_tool = Map.get(invocation, :tool_name) || Map.get(invocation, "tool_name")
    invocation_delegation = Map.get(invocation, :delegated_from)

    if is_binary(invocation_delegation) do
      {:error, Error.new(:forbidden, "delegation cannot expand tool authority")}
    else
      validate_tool_match(authority, descriptor, invocation, tool_name, invocation_tool, grants)
    end
  end

  defp validate_tool_match(authority, descriptor, invocation, tool_name, invocation_tool, grants) do
    if tool_name != invocation_tool do
      {:error,
       Error.new(:forbidden, "tool descriptor does not match invocation",
         details: %{descriptor: tool_name, invocation: invocation_tool}
       )}
    else
      if tool_name in grants do
        validate_revision(authority, descriptor, tool_name)
      else
        {:error,
         Error.new(:forbidden, "tool is not authorized",
           details: %{tool: tool_name, invocation: invocation}
         )}
      end
    end
  end

  defp validate_revision(authority, descriptor, tool_name) do
    revisions = Map.get(authority, :tool_revisions, Map.get(authority, "tool_revisions"))

    invocation_revision =
      if is_map(revisions) and Map.has_key?(revisions, tool_name),
        do: Map.get(revisions, tool_name),
        else: Map.get(authority, :tool_revision, Map.get(authority, "tool_revision"))

    descriptor_revision =
      Map.get(descriptor, :tool_revision) || Map.get(descriptor, "tool_revision")

    if is_integer(invocation_revision) and invocation_revision == descriptor_revision do
      {:ok, tool_name}
    else
      {:error,
       Error.new(:forbidden, "tool descriptor revision is not authorized",
         details: %{authorized: invocation_revision, descriptor: descriptor_revision}
       )}
    end
  end
end
