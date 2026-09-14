defmodule Backplane.AgentRuntime.Command do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Authorized command execution with environment allowlists and output caps.

  Shell interpretation is a separate capability. This module never claims OS
  sandbox guarantees; supported cleanup is declared by the CommandPort backend.
  """

  @type t :: map()

  @default_output_limit 1_048_576

  @default_deadline_limit 300_000

  @callback start(map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback read(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}

  @callback cancel(map(), map()) :: :ok | {:error, Error.t()}

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(namespace) when is_map(namespace) do
    with {:ok, adapter} <- validate_adapter(namespace),
         {:ok, allowed_environment} <- validate_environment(namespace) do
      {:ok,
       %{
         adapter: adapter,
         allowed_environment: allowed_environment,
         job_limit: Map.get(namespace, :job_limit, 1),
         output_limit: Map.get(namespace, :output_limit, @default_output_limit),
         deadline_limit: Map.get(namespace, :deadline_limit, @default_deadline_limit),
         workspace_key: Map.get(namespace, :workspace_key),
         server: Map.get(namespace, :server)
       }}
    end
  end

  @spec start(t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def start(command, invocation, opts \\ []) when is_map(command) and is_map(invocation) do
    with {:ok, executable} <- require_binary(invocation, :executable, "executable"),
         {:ok, _} <- reject_shell_string(executable),
         {:ok, arguments} <- validate_arguments(invocation),
         {:ok, owner_run_id} <- require_binary(invocation, :owner_run_id, "owner run"),
         {:ok, workspace} <- require_binary(invocation, :workspace, "workspace"),
         {:ok, environment} <- validate_environment(command, invocation),
         {:ok, limits} <- validate_limits(command, opts) do
      request =
        invocation
        |> Map.merge(%{
          executable: executable,
          arguments: arguments,
          owner_run_id: owner_run_id,
          workspace: workspace,
          environment: environment
        })
        |> Map.merge(limits)

      command.adapter.start(command, request, opts)
    end
  end

  @spec read(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read(command, invocation, job, opts \\ [])
      when is_map(command) and is_map(invocation) and is_map(job) do
    with {:ok, owner_run_id} <- require_binary(invocation, :owner_run_id, "owner run"),
         {:ok, _} <- validate_job_owner(job, owner_run_id),
         {:ok, cursor} <- validate_cursor(opts) do
      command.adapter.read(command, invocation, job, Keyword.put(opts, :cursor, cursor))
    end
  end

  defp reject_shell_string(executable) do
    if String.contains?(executable, " ") do
      {:error,
       Error.new(:validation, "shell interpretation is not enabled for executable strings")}
    else
      {:ok, executable}
    end
  end

  @spec cancel(t(), map()) :: :ok | {:error, Error.t()}
  def cancel(command, invocation) when is_map(command) and is_map(invocation) do
    with {:ok, _owner_run_id} <- require_binary(invocation, :owner_run_id, "owner run") do
      command.adapter.cancel(command, invocation)
    end
  end

  def workspace_conflict?(%{workspace: workspace}, %{workspace: other_workspace})
      when is_binary(workspace) and is_binary(other_workspace) do
    workspace == other_workspace
  end

  def workspace_conflict?(_command, _invocation), do: false

  defp validate_adapter(namespace) do
    adapter = Map.get(namespace, :adapter)

    if is_atom(adapter) do
      {:ok, adapter}
    else
      {:error, Error.new(:validation, "adapter is required")}
    end
  end

  defp validate_environment(namespace) do
    environment = Map.get(namespace, :allowed_environment)

    if is_map(environment) do
      {:ok, environment}
    else
      {:error, Error.new(:validation, "allowed_environment must be a map")}
    end
  end

  defp validate_arguments(invocation) do
    arguments = Map.get(invocation, :arguments)

    if is_list(arguments) do
      {:ok, arguments}
    else
      {:error, Error.new(:validation, "arguments must be a list")}
    end
  end

  defp validate_limits(command, opts) do
    deadline = Keyword.get(opts, :deadline_limit, command.deadline_limit)
    output = Keyword.get(opts, :output_limit, command.output_limit)

    if is_integer(deadline) and deadline in 1..command.deadline_limit and
         is_integer(output) and output in 1..command.output_limit do
      {:ok, %{deadline_limit: deadline, output_limit: output}}
    else
      {:error,
       Error.new(:validation, "command limits must be positive and within declared bounds")}
    end
  end

  defp validate_cursor(opts) do
    cursor = Keyword.get(opts, :cursor)

    if is_integer(cursor) and cursor >= 0 do
      {:ok, cursor}
    else
      {:error, Error.new(:validation, "cursor is required and must be non-negative")}
    end
  end

  defp validate_job_owner(job, owner_run_id) do
    if is_map(job) and job.owner_run_id == owner_run_id do
      {:ok, job}
    else
      {:error, Error.new(:forbidden, "command job owner does not match invocation owner")}
    end
  end

  defp validate_environment(command, invocation) do
    requested = Map.get(invocation, :environment, %{})
    allowed = command.allowed_environment

    if Enum.all?(Map.keys(requested), &Map.has_key?(allowed, &1)) do
      {:ok, Map.take(requested, Map.keys(requested))}
    else
      {:error, Error.new(:forbidden, "requested environment variables are not allowed")}
    end
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
