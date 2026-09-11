defmodule Backplane.AgentRuntime.ToolsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Tools

  defmodule MemoryPort do
    @callback search(map(), map(), keyword()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    @callback store(map(), map(), keyword()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    def search(_caller, _query, _opts), do: {:ok, %{results: [], provenance: "fake"}}

    def store(_caller, _record, _opts), do: {:ok, %{stored: true, provenance: "fake"}}
  end

  defmodule SkillPort do
    @callback list(map(), map(), keyword()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    @callback load(map(), map(), map(), keyword()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    def list(_caller, _query, _opts), do: {:ok, %{skills: [], provenance: "fake"}}

    def load(_caller, _descriptor, _resource, _opts), do: {:ok, %{content: "safe"}}
  end

  defmodule PlanPort do
    @callback read(map()) :: {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    @callback update(map(), integer(), map()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    def read(_caller), do: {:ok, %{content: %{}, revision: 1}}

    def update(_caller, expected_revision, _content),
      do: {:ok, %{revision: expected_revision + 1}}
  end

  defmodule ResourcePort do
    @callback read(map(), keyword()) :: {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    @callback write(map(), map(), keyword()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    def read(_reference, _opts), do: {:ok, %{content: "data", provenance: "fake"}}

    def write(_reference, _content, _opts), do: {:ok, %{written: true, revision: 2}}
  end

  defmodule CommandPort do
    @callback start(map(), keyword()) :: {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    @callback read(map(), map(), keyword()) ::
                {:ok, map()} | {:error, Backplane.AgentRuntime.Error.t()}

    @callback cancel(map(), map()) :: :ok | {:error, Backplane.AgentRuntime.Error.t()}

    def start(_invocation, _opts), do: {:ok, %{job_id: "job_1"}}

    def read(_invocation, _job, _opts), do: {:ok, %{payload: "chunk", cursor: 1}}

    def cancel(_invocation, _job), do: :ok
  end

  test "omits absent backend tool families" do
    {:ok, tools} = Tools.new(%{})

    assert Tools.available_tools(tools) == []

    assert {:error, %Error{class: :unsupported_capability}} =
             Tools.memory_search(tools, %{memory_scope: "task_1"}, %{scope: "task_1"})

    assert {:error, %Error{class: :unsupported_capability}} =
             Tools.skill_load(
               tools,
               %{agent_id: "agent_1"},
               %{bundle_revision: "1", digest: "d"},
               %{}
             )
  end

  test "restricts memory to the caller scope and bounded fake-port output" do
    {:ok, tools} = Tools.new(%{memory_port: MemoryPort})

    assert Tools.available_tools(tools) == [:memory]

    assert {:ok, %{provenance: "fake"}} =
             Tools.memory_search(tools, %{memory_scope: "task_1"}, %{scope: "task_1"})

    assert {:error, %Error{class: :forbidden}} =
             Tools.memory_search(tools, %{memory_scope: "task_1"}, %{scope: "other"})
  end

  test "pins Skill bundles and never grants tool authority through content" do
    {:ok, tools} = Tools.new(%{skill_port: SkillPort})

    assert Tools.available_tools(tools) == [:skill]

    assert {:ok, %{content: "safe"}} =
             Tools.skill_load(
               tools,
               %{agent_id: "agent_1", granted_tools: []},
               %{bundle_revision: "1", digest: "digest"},
               %{}
             )

    assert {:error, %Error{}} =
             Tools.skill_load(tools, %{agent_id: "agent_1"}, %{}, %{})
  end

  test "requires plan, resource, and command ports before exposing families" do
    {:ok, tools} = Tools.new(%{})

    assert Tools.available_tools(tools) == []

    assert {:error, %Error{class: :unsupported_capability}} = Tools.plan_read(tools, %{})

    assert {:error, %Error{class: :unsupported_capability}} =
             Tools.resource_read(tools, %{}, %{path: "/tmp"})

    assert {:error, %Error{class: :unsupported_capability}} =
             Tools.command_start(tools, %{}, %{})
  end

  test "binds resource and command operations to caller scope and run ownership" do
    {:ok, tools} = Tools.new(%{resource_port: ResourcePort, command_port: CommandPort})

    assert {:ok, %{provenance: "fake"}} =
             Tools.resource_read(
               tools,
               %{resource_scope: "/tmp/workspace"},
               %{path: "/tmp/workspace/file", expected_revision: 1}
             )

    assert {:error, %Error{class: :forbidden}} =
             Tools.resource_read(
               tools,
               %{resource_scope: "/tmp/workspace"},
               %{path: "/tmp/other/file", expected_revision: 1}
             )

    caller = %{run_id: "run_1"}

    assert {:ok, %{job_id: "job_1"}} =
             Tools.command_start(tools, caller, %{owner_run_id: "run_1"})

    assert {:error, %Error{class: :forbidden}} =
             Tools.command_start(tools, caller, %{owner_run_id: "run_2"})
  end
end
