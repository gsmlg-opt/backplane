defmodule Backplane.Hub.InspectTest do
  use ExUnit.Case, async: true

  alias Backplane.Hub.Inspect
  alias Backplane.Registry.{Tool, ToolRegistry}

  setup do
    # Ensure ToolRegistry ETS table exists
    unless :ets.whereis(:backplane_tools) != :undefined do
      :ets.new(:backplane_tools, [:named_table, :set, :public, read_concurrency: true])
    end

    # Register a test tool
    tool = %Tool{
      name: "test::hello",
      description: "A test tool",
      input_schema: %{"type" => "object", "properties" => %{}},
      origin: :native,
      module: __MODULE__,
      handler: :hello
    }

    :ets.insert(:backplane_tools, {tool.name, tool})

    on_exit(fn ->
      :ets.delete(:backplane_tools, "test::hello")
    end)

    :ok
  end

  test "introspect returns tool details for known tool" do
    assert {:ok, result} = Inspect.introspect("test::hello")
    assert result.name == "test::hello"
    assert result.description == "A test tool"
    assert result.origin == "native"
    assert result.upstream_name == nil
    assert result.upstream_healthy == nil
  end

  test "introspect returns error for unknown tool" do
    assert {:error, "Unknown tool: nonexistent::tool"} = Inspect.introspect("nonexistent::tool")
  end

  test "introspect includes input_schema" do
    assert {:ok, result} = Inspect.introspect("test::hello")
    assert result.input_schema == %{"type" => "object", "properties" => %{}}
  end
end
