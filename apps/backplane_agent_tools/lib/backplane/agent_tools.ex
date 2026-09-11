defmodule Backplane.AgentTools do
  alias Backplane.AgentRuntime.Tools

  @moduledoc """
  Optional tool-family namespace.

  Installing this package does not register tools. Hosts explicitly select and
  register descriptors through the runtime registry.
  """

  @type t :: map()

  @spec new(map()) :: {:ok, t()}
  def new(namespace) when is_map(namespace) do
    Tools.new(namespace)
  end

  @spec available_tools(t()) :: list(atom())
  def available_tools(tools) when is_map(tools) do
    Tools.available_tools(tools)
  end

  @spec plan_read(t(), map()) :: {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def plan_read(tools, caller) when is_map(tools) and is_map(caller) do
    Tools.plan_read(tools, caller)
  end

  @spec plan_update(t(), map(), integer(), map()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def plan_update(tools, caller, expected_revision, content)
      when is_map(tools) and is_map(caller) and is_integer(expected_revision) and is_map(content) do
    Tools.plan_update(tools, caller, expected_revision, content)
  end

  @spec resource_read(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def resource_read(tools, caller, reference, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(reference) and is_list(opts) do
    Tools.resource_read(tools, caller, reference, opts)
  end

  @spec resource_write(t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def resource_write(tools, caller, reference, content, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(reference) and is_map(content) and
             is_list(opts) do
    Tools.resource_write(tools, caller, reference, content, opts)
  end

  @spec command_start(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def command_start(tools, caller, invocation, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(invocation) and is_list(opts) do
    Tools.command_start(tools, caller, invocation, opts)
  end

  @spec command_read(t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def command_read(tools, caller, invocation, job, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(invocation) and is_map(job) and
             is_list(opts) do
    Tools.command_read(tools, caller, invocation, job, opts)
  end

  @spec command_cancel(t(), map(), map(), map()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def command_cancel(tools, caller, invocation, job)
      when is_map(tools) and is_map(caller) and is_map(invocation) and is_map(job) do
    Tools.command_cancel(tools, caller, invocation, job)
  end

  @spec memory_search(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def memory_search(tools, caller, query, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(query) and is_list(opts) do
    Tools.memory_search(tools, caller, query, opts)
  end

  @spec memory_store(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def memory_store(tools, caller, record, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(record) and is_list(opts) do
    Tools.memory_store(tools, caller, record, opts)
  end

  @spec skill_list(t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def skill_list(tools, caller, query \\ %{}, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(query) and is_list(opts) do
    Tools.skill_list(tools, caller, query, opts)
  end

  @spec skill_load(t(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}
  def skill_load(tools, caller, descriptor, resource, opts \\ [])
      when is_map(tools) and is_map(caller) and is_map(descriptor) and is_map(resource) and
             is_list(opts) do
    Tools.skill_load(tools, caller, descriptor, resource, opts)
  end
end
