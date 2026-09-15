defmodule FakeBackend do
  @moduledoc """
  Clean-consumer fixture proving host-injected Memory and Skill ports.
  """

  alias Backplane.AgentRuntime.Tools
  alias Backplane.AgentRuntime.Error

  defmodule MemoryPort do
    def search(_caller, _query, _opts), do: {:ok, %{results: [], provenance: "fake"}}
    def store(_caller, _record, _opts), do: {:ok, %{stored: true, provenance: "fake"}}
  end

  defmodule SkillPort do
    def list(_caller, _query, _opts), do: {:ok, %{skills: [], provenance: "fake"}}
    def load(_caller, _descriptor, _resource, _opts), do: {:ok, %{content: "safe"}}
  end

  def verify! do
    {:ok, tools} = Tools.new(%{memory_port: MemoryPort, skill_port: SkillPort})
    [:memory, :skill] = Tools.available_tools(tools)

    {:ok, %{provenance: "fake"}} =
      Tools.memory_search(tools, %{memory_scope: "task"}, %{scope: "task"})

    {:error, %Error{class: :forbidden}} =
      Tools.memory_search(tools, %{memory_scope: "task"}, %{scope: "another-task"})

    {:ok, %{content: "safe"}} =
      Tools.skill_load(
        tools,
        %{agent_id: "agent", granted_tools: []},
        %{bundle_revision: "1", digest: "digest"},
        %{}
      )

    :ok
  end
end
