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

  @callback write(map(), map(), map(), binary()) :: :ok | {:error, Error.t()}

  @optional_callbacks write: 4

  @callback cancel_confirmed(map(), map(), pos_integer()) :: :ok | {:error, Error.t()}
  @optional_callbacks cancel_confirmed: 3

  @callback reserve(map(), map()) :: :ok | {:error, Error.t()}
  @callback acknowledge_release(map(), map()) :: :ok | {:error, Error.t()}
  @optional_callbacks reserve: 2, acknowledge_release: 2

  @callback validate_refusal(map(), map(), Error.t()) :: :ok | {:error, Error.t()}
  @callback capabilities(map()) :: map()
  @optional_callbacks validate_refusal: 3, capabilities: 1

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

  @spec write(t(), map(), map(), binary()) :: :ok | {:error, Error.t()}
  def write(command, invocation, job, chars)
      when is_map(command) and is_map(invocation) and is_map(job) and is_binary(chars) do
    with {:ok, owner_run_id} <- require_binary(invocation, :owner_run_id, "owner run"),
         {:ok, _} <- validate_job_owner(job, owner_run_id) do
      if function_exported?(command.adapter, :write, 4) do
        command.adapter.write(command, invocation, job, chars)
      else
        {:error,
         Error.new(:unsupported_capability, "command backend does not support stdin writes")}
      end
    end
  end

  def write(_command, _invocation, _job, _chars),
    do: {:error, Error.new(:validation, "command write arguments are malformed")}

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

  @spec cancel_confirmed(t(), map(), pos_integer()) :: :ok | {:error, Error.t()}
  def cancel_confirmed(command, invocation, timeout)
      when is_map(command) and is_map(invocation) and is_integer(timeout) and timeout > 0 do
    with {:ok, _} <- require_binary(invocation, :owner_run_id, "owner run") do
      if function_exported?(command.adapter, :cancel_confirmed, 3) do
        command.adapter.cancel_confirmed(command, invocation, timeout)
      else
        {:error,
         Error.new(
           :unknown_outcome,
           "command backend does not support per-invocation termination"
         )}
      end
    end
  end

  def workspace_conflict?(%{workspace: workspace}, %{workspace: other_workspace})
      when is_binary(workspace) and is_binary(other_workspace) do
    workspace == other_workspace
  end

  def workspace_conflict?(_command, _invocation), do: false

  @doc "Reserve a trusted session before launch; legacy adapters retain uncertain cleanup semantics."
  def reserve(command, invocation), do: lifecycle_callback(command, :reserve, invocation)

  @doc "Acknowledge consumed cleanup evidence so a backend may retire its pinned receipt."
  def acknowledge_release(command, invocation),
    do: lifecycle_callback(command, :acknowledge_release, invocation)

  @doc "Validate backend-issued proof of non-execution; error metadata alone is not proof."
  def validate_refusal(command, invocation, error) do
    if function_exported?(command.adapter, :validate_refusal, 3),
      do: command.adapter.validate_refusal(command, invocation, error),
      else: {:error, Error.new(:unknown_outcome, "command refusal is unverified")}
  end

  @doc "Host-verified PTY dimensions for this platform, or an unsupported capability error."
  def terminal(command) do
    capabilities =
      if function_exported?(command.adapter, :capabilities, 1),
        do: command.adapter.capabilities(command),
        else: %{}

    case capabilities do
      %{pty: %{verified: true, platforms: platforms} = terminal} when is_list(platforms) ->
        rows = Map.get(terminal, :rows, 24)
        columns = Map.get(terminal, :columns, 80)

        if :os.type() in platforms and is_integer(rows) and rows in 1..1_000 and
             is_integer(columns) and columns in 1..1_000 do
          {:ok, %{rows: rows, columns: columns}}
        else
          {:error, Error.new(:unsupported_capability, "PTY execution is unavailable")}
        end

      _ ->
        {:error, Error.new(:unsupported_capability, "PTY execution is unavailable")}
    end
  end

  defp lifecycle_callback(command, callback, invocation) do
    if function_exported?(command.adapter, callback, 2),
      do: apply(command.adapter, callback, [command, invocation]),
      else: :ok
  end

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
