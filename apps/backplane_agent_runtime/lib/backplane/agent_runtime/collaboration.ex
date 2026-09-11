defmodule Backplane.AgentRuntime.Collaboration do
  alias Backplane.AgentRuntime.AgentHost
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Message

  @moduledoc """
  Opt-in collaboration wrappers over shared runtime APIs.

  Wrappers add no alternate executor or elevated privilege. Notifications and
  status queries never start model work.
  """

  @tool_names [
    :agent_discover,
    :agent_spawn,
    :agent_delegate,
    :agent_send,
    :run_status,
    :run_wait,
    :run_cancel,
    :ask_user
  ]

  @type t :: map()

  @spec register_tools(map(), keyword()) :: {:ok, map(), list()} | {:error, Error.t()}
  def register_tools(host, opts \\ []) when is_map(host) and is_list(opts) do
    selected = Keyword.get(opts, :tools, [])

    if Enum.all?(selected, &(&1 in @tool_names)) do
      {:ok, host, selected}
    else
      {:error, Error.new(:validation, "invalid collaboration tool name")}
    end
  end

  @spec discover(t(), map(), String.t()) :: {:ok, list()} | {:error, Error.t()}
  def discover(host, viewer, prefix) when is_map(host) and is_binary(prefix) do
    if visible?(host, viewer, prefix) do
      {:ok, Map.keys(host.agents)}
    else
      {:ok, []}
    end
  end

  @spec delegate(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def delegate(host, request) when is_map(host) and is_map(request) do
    with {:ok, target} <- require_binary(request, :target_agent_id, "target agent"),
         {:ok, delegated_from} <- require_binary(request, :delegated_from, "delegating run"),
         {:ok, idempotency_key} <- require_binary(request, :idempotency_key, "idempotency key") do
      case AgentHost.submit(host, target) do
        {:ok, host, receipt} ->
          {:ok,
           %{
             host: host,
             receipt: %{
               status: receipt.status,
               agent_id: receipt.agent_id,
               active_runs: receipt.active_runs,
               delegated_from: delegated_from,
               idempotency_key: idempotency_key
             }
           }}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @spec send(t(), map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def send(host, input) when is_map(host) and is_map(input) do
    with {:ok, message} <- Message.build(input),
         false <- Message.task_request?(message) do
      {:ok, host, %{delivered: true, correlation_id: message.correlation_id}}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec status(t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def status(host, agent_id) when is_map(host) and is_binary(agent_id) do
    case Map.get(host.agents, agent_id) do
      nil ->
        {:error, Error.new(:not_found, "agent not found", details: %{agent: agent_id})}

      agent ->
        {:ok,
         %{
           agent_id: agent.agent_id,
           lifecycle: agent.lifecycle,
           status: agent.status,
           active_runs: Map.get(agent, :active_runs, 0)
         }}
    end
  end

  @spec wait(t(), String.t()) ::
          {:ok, %{status: :waiting, run_id: String.t()}} | {:error, Error.t()}
  def wait(_host, run_id) when is_binary(run_id) do
    {:ok, %{status: :waiting, run_id: run_id}}
  end

  @spec cancel(t(), String.t()) ::
          {:ok, %{status: :cancelling, run_id: String.t()}} | {:error, Error.t()}
  def cancel(_host, run_id) when is_binary(run_id) do
    {:ok, %{status: :cancelling, run_id: run_id}}
  end

  @spec ask_user(map(), String.t()) :: {:error, Error.t()}
  def ask_user(_input, nil),
    do: {:error, Error.new(:forbidden, "no interaction resolver configured")}

  @spec ask_user(map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def ask_user(input, resolver) when is_map(input) and is_binary(resolver) do
    {:ok,
     %{resolved: true, correlation_id: Map.get(input, :correlation_id), resolver_id: resolver}}
  end

  defp visible?(_host, viewer, prefix) do
    is_binary(viewer) and String.starts_with?(viewer, prefix)
  end

  defp require_binary(input, key, label) do
    value = Map.get(input, key)

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, Error.new(:validation, "#{label} is required")}
    end
  end
end
