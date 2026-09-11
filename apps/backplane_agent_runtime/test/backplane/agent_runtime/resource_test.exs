defmodule Backplane.AgentRuntime.ResourceTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Resource

  defmodule FakeAdapter do
    @behaviour Backplane.AgentRuntime.Resource

    @impl Backplane.AgentRuntime.Resource
    def read(_resource, reference, _opts) do
      {:ok, %{content: "data", revision: reference.expected_revision + 1}}
    end

    @impl Backplane.AgentRuntime.Resource
    def write(_resource, reference, _content, _opts) do
      {:ok, %{revision: reference.expected_revision + 1, written: true}}
    end
  end

  describe "scoped resource operations" do
    test "reads within scope and validates bounded output" do
      {:ok, resource} = Resource.new(%{adapter: FakeAdapter, scope: "/tmp/workspace"})

      assert {:ok, result} =
               Resource.read(
                 resource,
                 %{path: "/tmp/workspace/file", expected_revision: 1},
                 output_limit: 100
               )

      assert result.content == "data"
    end

    test "rejects traversal outside declared scope" do
      {:ok, resource} = Resource.new(%{adapter: FakeAdapter, scope: "/tmp/workspace"})

      assert {:error, %Backplane.AgentRuntime.Error{class: :forbidden}} =
               Resource.read(resource, %{path: "/outside/file", expected_revision: 1})
    end

    test "rejects stale writes without silent overwrite" do
      {:ok, resource} = Resource.new(%{adapter: FakeAdapter, scope: "/tmp/workspace"})

      assert {:error, %Backplane.AgentRuntime.Error{}} =
               Resource.write(
                 resource,
                 %{path: "/tmp/workspace/file", expected_revision: 2},
                 %{payload: "new", expected_revision: 1}
               )
    end
  end
end
