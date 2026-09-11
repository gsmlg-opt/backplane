defmodule Backplane.AgentRuntime.AgentHost do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Runtime instance agent registry for hosted and owner-bound identities.

  The host is immutable data and starts no processes. It enforces namespace
  isolation, bounded task admission, stable identity, and distinct trusted
  stop from model-visible run cancellation.
  """

  @type t :: map()

  @valid_lifecycles [:hosted, :owner_bound]

  @spec new(String.t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def new(runtime_id, policy) when is_binary(runtime_id) and is_map(policy) do
    with {:ok, max_agents} <- non_negative(policy, :max_agents),
         {:ok, max_active_runs} <- non_negative(policy, :max_active_runs) do
      {:ok,
       %{
         runtime_id: runtime_id,
         max_agents: max_agents,
         max_active_runs: max_active_runs,
         agents: %{}
       }}
    end
  end

  @spec register(t(), map()) :: {:ok, t(), map()} | {:error, Error.t()}
  def register(host, agent) when is_map(host) and is_map(agent) do
    with {:ok, agent_id} <- require_binary(agent, :agent_id, "agent_id"),
         {:ok, lifecycle} <- validate_lifecycle(agent),
         {:ok, owner} <- validate_owner(agent) do
      case Map.get(host.agents, agent_id) do
        %{lifecycle: lifecycle, owner: existing_owner} ->
          {:ok, host, %{agent_id: agent_id, lifecycle: lifecycle, owner: existing_owner}}

        nil ->
          if map_size(host.agents) >= host.max_agents do
            {:error, Error.new(:overloaded, "agent limit exceeded")}
          else
            agent = %{agent_id: agent_id, lifecycle: lifecycle, owner: owner, status: :active}

            {:ok, %{host | agents: Map.put(host.agents, agent_id, agent)},
             %{agent_id: agent_id, lifecycle: lifecycle, owner: owner}}
          end
      end
    end
  end

  @spec submit(t(), String.t()) :: {:ok, t(), map()} | {:error, Error.t()}
  def submit(host, agent_id) when is_map(host) and is_binary(agent_id) do
    case Map.get(host.agents, agent_id) do
      nil ->
        {:error, Error.new(:not_found, "agent not found", details: %{agent: agent_id})}

      %{status: :stopped} ->
        {:error, Error.new(:not_found, "agent is stopped", details: %{agent: agent_id})}

      agent when not is_map_key(agent, :active_runs) ->
        agent = Map.put(agent, :active_runs, 0)
        submit(%{host | agents: Map.put(host.agents, agent_id, agent)}, agent_id)

      %{active_runs: active} = agent when is_integer(active) and active < host.max_active_runs ->
        agent = %{agent | active_runs: active + 1}

        {:ok, %{host | agents: Map.put(host.agents, agent_id, agent)},
         %{status: :accepted, agent_id: agent_id, active_runs: active + 1}}

      %{active_runs: active} when is_integer(active) ->
        {:error,
         Error.new(:overloaded, "agent work limit exceeded",
           details: %{agent: agent_id, active_runs: active}
         )}
    end
  end

  @spec stop(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def stop(host, agent_id) when is_map(host) and is_binary(agent_id) do
    case Map.get(host.agents, agent_id) do
      nil ->
        {:error, Error.new(:not_found, "agent not found", details: %{agent: agent_id})}

      agent ->
        {:ok, %{host | agents: Map.put(host.agents, agent_id, %{agent | status: :stopped})}}
    end
  end

  defp non_negative(policy, key) do
    value = Map.get(policy, key)

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, Error.new(:validation, "policy #{key} must be non-negative")}
    end
  end

  defp validate_lifecycle(%{lifecycle: lifecycle}) when lifecycle in @valid_lifecycles,
    do: {:ok, lifecycle}

  defp validate_lifecycle(_), do: {:error, Error.new(:validation, "invalid agent lifecycle")}

  defp validate_owner(%{lifecycle: :hosted, owner: nil}), do: {:ok, nil}

  defp validate_owner(%{lifecycle: :owner_bound, owner: owner}) when is_binary(owner),
    do: {:ok, owner}

  defp validate_owner(_), do: {:error, Error.new(:validation, "invalid owner reference")}

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Error.new(:validation, "#{label} is required")}
    end
  end
end
