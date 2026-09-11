defmodule Backplane.AgentToolsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentTools
  alias Backplane.AgentRuntime.Error

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

  test "omits absent backend tool families and rejects absent wrappers" do
    {:ok, tools} = AgentTools.new(%{})

    assert AgentTools.available_tools(tools) == []

    assert {:error, %Error{class: :unsupported_capability}} =
             AgentTools.memory_search(tools, %{memory_scope: "task_1"}, %{scope: "task_1"})

    assert {:error, %Error{class: :unsupported_capability}} =
             AgentTools.skill_load(
               tools,
               %{agent_id: "agent_1"},
               %{bundle_revision: "1", digest: "d"},
               %{}
             )
  end

  test "wraps configured MemoryPort and SkillPort without granting tool authority" do
    {:ok, tools} = AgentTools.new(%{memory_port: MemoryPort, skill_port: SkillPort})

    assert AgentTools.available_tools(tools) == [:memory, :skill]

    assert {:ok, %{provenance: "fake"}} =
             AgentTools.memory_search(tools, %{memory_scope: "task_1"}, %{scope: "task_1"})

    assert {:ok, %{content: "safe"}} =
             AgentTools.skill_load(
               tools,
               %{agent_id: "agent_1", granted_tools: []},
               %{bundle_revision: "1", digest: "digest"},
               %{}
             )
  end
end
