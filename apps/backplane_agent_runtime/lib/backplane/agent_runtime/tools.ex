defmodule Backplane.AgentRuntime.Tools do
  alias Backplane.AgentRuntime.Error

  @moduledoc """
  Backend-conditional optional tool family wrappers.

  Each family is omitted until its port is explicitly configured. The wrapper
  never creates an alternate executor, service backend, or elevated authority.
  """

  @default_output_limit 1_048_576

  @type t :: map()

  @callback memory_search(t(), map(), map(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback memory_store(t(), map(), map(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback skill_list(t(), map(), map(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  @callback skill_load(t(), map(), map(), map(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}

  @spec new(map()) :: {:ok, t()}
  def new(namespace) when is_map(namespace) do
    {:ok,
     %{
       resource_port: Map.get(namespace, :resource_port),
       command_port: Map.get(namespace, :command_port),
       plan_port: Map.get(namespace, :plan_port),
       memory_port: Map.get(namespace, :memory_port),
       skill_port: Map.get(namespace, :skill_port),
       output_limit: Map.get(namespace, :output_limit, @default_output_limit)
     }}
  end

  @spec available_tools(t()) :: list(atom())
  def available_tools(tools) when is_map(tools) do
    ports =
      [
        file: tools.resource_port,
        exec: tools.command_port,
        plan: tools.plan_port,
        memory: tools.memory_port,
        skill: tools.skill_port
      ]

    for {family, port} <- ports, port != nil, into: [], do: family
  end

  @spec plan_read(t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def plan_read(tools, caller) when is_map(tools) and is_map(caller) do
    with {:ok, port} <- require_port(tools.plan_port, "PlanPort") do
      port.read(caller)
    end
  end

  @spec plan_update(t(), map(), integer(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def plan_update(tools, caller, expected_revision, content)
      when is_map(tools) and is_map(caller) and is_integer(expected_revision) and is_map(content) do
    with {:ok, port} <- require_port(tools.plan_port, "PlanPort") do
      port.update(caller, expected_revision, content)
    end
  end

  @spec resource_read(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def resource_read(tools, caller, reference, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(reference) and is_list(opts) do
    with {:ok, port} <- require_port(tools.resource_port, "ResourcePort"),
         {:ok, _} <- require_resource_scope(caller, reference) do
      with {:ok, result} <- port.read(reference, opts) do
        validate_output(result, tools.output_limit)
      end
    end
  end

  @spec resource_write(t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def resource_write(tools, caller, reference, content, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(reference) and is_map(content) and
             is_list(opts) do
    with {:ok, port} <- require_port(tools.resource_port, "ResourcePort"),
         {:ok, _} <- require_resource_scope(caller, reference) do
      with {:ok, result} <- port.write(reference, content, opts) do
        validate_output(result, tools.output_limit)
      end
    end
  end

  @spec command_start(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def command_start(tools, caller, invocation, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(invocation) and is_list(opts) do
    with {:ok, port} <- require_port(tools.command_port, "CommandPort"),
         {:ok, _} <- require_run_owner(caller, invocation) do
      with {:ok, result} <- port.start(invocation, opts) do
        validate_output(result, tools.output_limit)
      end
    end
  end

  @spec command_read(t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def command_read(tools, caller, invocation, job, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(invocation) and is_map(job) and
             is_list(opts) do
    with {:ok, port} <- require_port(tools.command_port, "CommandPort"),
         {:ok, _} <- require_run_owner(caller, invocation) do
      with {:ok, result} <- port.read(invocation, job, opts) do
        validate_output(result, tools.output_limit)
      end
    end
  end

  @spec command_cancel(t(), map(), map(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def command_cancel(tools, caller, invocation, job)
      when is_map(tools) and is_map(caller) and is_map(invocation) and is_map(job) do
    with {:ok, port} <- require_port(tools.command_port, "CommandPort"),
         {:ok, _} <- require_run_owner(caller, invocation) do
      port.cancel(invocation, job)
    end
  end

  @spec memory_search(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def memory_search(tools, caller, query, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(query) and is_list(opts) do
    with {:ok, port} <- require_port(tools.memory_port, "MemoryPort"),
         {:ok, _} <- require_scope(caller, query),
         {:ok, result} <- port.search(caller, query, opts) do
      validate_output(result, tools.output_limit)
    end
  end

  @spec memory_store(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def memory_store(tools, caller, record, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(record) and is_list(opts) do
    with {:ok, port} <- require_port(tools.memory_port, "MemoryPort"),
         {:ok, _} <- require_scope(caller, record),
         {:ok, result} <- port.store(caller, record, opts) do
      validate_output(result, tools.output_limit)
    end
  end

  @spec skill_list(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def skill_list(tools, caller, query \\ %{}, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(query) and is_list(opts) do
    with {:ok, port} <- require_port(tools.skill_port, "SkillPort"),
         {:ok, result} <- port.list(caller, query, opts) do
      validate_output(result, tools.output_limit)
    end
  end

  @spec skill_load(t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def skill_load(tools, caller, descriptor, resource, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(descriptor) and is_map(resource) and
             is_list(opts) do
    with {:ok, port} <- require_port(tools.skill_port, "SkillPort"),
         {:ok, _} <- require_binary(descriptor, :bundle_revision, "bundle_revision"),
         {:ok, _} <- require_binary(descriptor, :digest, "digest"),
         {:ok, result} <- port.load(caller, descriptor, resource, opts) do
      validate_output(result, tools.output_limit)
    end
  end

  defp require_port(nil, label) do
    {:error, Error.new(:unsupported_capability, "#{label} is not configured")}
  end

  defp require_port(port, _label) when is_atom(port), do: {:ok, port}

  defp require_port(_port, _label) do
    {:error, Error.new(:validation, "invalid port configuration")}
  end

  defp require_scope(caller, input) do
    caller_scope = Map.get(caller, :memory_scope)
    requested_scope = Map.get(input, :scope)

    if is_binary(caller_scope) and requested_scope == caller_scope do
      {:ok, caller_scope}
    else
      {:error, Error.new(:forbidden, "memory scope is not authorized")}
    end
  end

  defp require_resource_scope(caller, reference) do
    caller_scope = Map.get(caller, :resource_scope)
    path = Map.get(reference, :path)

    if is_binary(caller_scope) and is_binary(path) and String.starts_with?(path, caller_scope) do
      {:ok, path}
    else
      {:error, Error.new(:forbidden, "resource scope is not authorized")}
    end
  end

  defp require_run_owner(caller, invocation) do
    caller_run = Map.get(caller, :run_id)
    invocation_run = Map.get(invocation, :owner_run_id)

    if is_binary(caller_run) and invocation_run == caller_run do
      {:ok, caller_run}
    else
      {:error, Error.new(:forbidden, "command run ownership is not authorized")}
    end
  end

  defp require_binary(input, key, label) do
    if is_binary(Map.get(input, key)) and Map.get(input, key) != "" do
      {:ok, Map.get(input, key)}
    else
      {:error, Error.new(:validation, "#{label} is required")}
    end
  end

  defp validate_output(result, limit) when is_map(result) do
    size = :erlang.external_size(result)

    if size > limit do
      {:error,
       Error.new(:resource_conflict, "tool output exceeds the configured bound",
         details: %{limit: limit, size: size}
       )}
    else
      {:ok, result}
    end
  end

  defp validate_output(_result, _limit) do
    {:error, Error.new(:malformed_result, "tool output must be a map")}
  end
end
