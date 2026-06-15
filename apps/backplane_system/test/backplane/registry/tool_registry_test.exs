defmodule Backplane.Registry.ToolRegistryTest do
  use ExUnit.Case

  alias Backplane.Registry.{Tool, ToolRegistry}

  setup do
    # Clear the ETS table between tests
    :ets.delete_all_objects(:backplane_tools)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_tools)
    end)

    :ok
  end

  defp sample_tool(name \\ "test::example", opts \\ []) do
    %Tool{
      name: name,
      description: Keyword.get(opts, :description, "A test tool"),
      input_schema: Keyword.get(opts, :input_schema, %{"type" => "object"}),
      origin: Keyword.get(opts, :origin, :native),
      module: Keyword.get(opts, :module, TestModule)
    }
  end

  describe "register_native/1" do
    test "registers a tool module and appears in list_all" do
      tool = sample_tool()
      assert :ok = ToolRegistry.register_native(tool)

      tools = ToolRegistry.list_all()
      assert length(tools) == 1
      assert hd(tools).name == "test::example"
    end

    test "tool is resolvable via resolve/1" do
      tool = sample_tool()
      ToolRegistry.register_native(tool)

      assert {:native, TestModule, _handler} = ToolRegistry.resolve("test::example")
    end
  end

  describe "list_all/0" do
    test "returns empty list when no tools registered" do
      assert ToolRegistry.list_all() == []
    end

    test "returns sorted list of all tools" do
      ToolRegistry.register_native(sample_tool("b::tool"))
      ToolRegistry.register_native(sample_tool("a::tool"))

      tools = ToolRegistry.list_all()
      assert length(tools) == 2
      assert Enum.at(tools, 0).name == "a::tool"
      assert Enum.at(tools, 1).name == "b::tool"
    end

    test "coalesces stale path-like upstream prefixes" do
      stale_tool =
        sample_tool("/github::search",
          origin: {:upstream, "/github"},
          description: "Search repositories"
        )

      normalized_tool =
        sample_tool("github::search",
          origin: {:upstream, "github"},
          description: "Search repositories"
        )

      :ets.insert(:backplane_tools, [
        {stale_tool.name, stale_tool},
        {normalized_tool.name, normalized_tool}
      ])

      assert [%Tool{name: "github::search", origin: {:upstream, "github"}}] =
               ToolRegistry.list_all()
    end
  end

  describe "resolve/1" do
    test "returns {:native, module, handler} for native tool" do
      ToolRegistry.register_native(sample_tool())
      assert {:native, TestModule, _handler} = ToolRegistry.resolve("test::example")
    end

    test "resolves normalized name for stale path-like upstream row" do
      pid = self()

      stale_tool =
        %Tool{
          name: "/github::search",
          description: "Search repositories",
          input_schema: %{},
          origin: {:upstream, "/github"},
          upstream_pid: pid,
          original_name: "search"
        }

      :ets.insert(:backplane_tools, {stale_tool.name, stale_tool})

      assert {:upstream, ^pid, "search", _timeout} = ToolRegistry.resolve("github::search")
    end

    test "returns :not_found for unregistered name" do
      assert :not_found = ToolRegistry.resolve("nonexistent::tool")
    end
  end

  describe "count/0" do
    test "returns number of registered tools" do
      assert ToolRegistry.count() == 0

      ToolRegistry.register_native(sample_tool("a::tool"))
      assert ToolRegistry.count() == 1

      ToolRegistry.register_native(sample_tool("b::tool"))
      assert ToolRegistry.count() == 2
    end
  end

  describe "register_upstream/3" do
    test "registers upstream tools with prefix" do
      upstream_tools = [
        %Tool{
          name: "read_file",
          description: "Read a file",
          input_schema: %{},
          origin: :native
        }
      ]

      pid = self()
      assert :ok = ToolRegistry.register_upstream("fs", pid, upstream_tools)

      tools = ToolRegistry.list_all()
      assert length(tools) == 1
      assert hd(tools).name == "fs::read_file"
    end

    test "normalizes path-like upstream prefixes" do
      upstream_tools = [
        %Tool{
          name: "search",
          description: "Search repositories",
          input_schema: %{},
          origin: :native
        }
      ]

      pid = self()
      assert :ok = ToolRegistry.register_upstream("/github", pid, upstream_tools)

      assert [%Tool{name: "github::search", origin: {:upstream, "github"}}] =
               ToolRegistry.list_all()

      assert {:upstream, ^pid, "search", _timeout} = ToolRegistry.resolve("github::search")
      assert :not_found = ToolRegistry.resolve("/github::search")
    end

    test "stores upstream_pid for forwarding" do
      upstream_tools = [
        %Tool{name: "query", description: "Run query", input_schema: %{}, origin: :native}
      ]

      pid = self()
      ToolRegistry.register_upstream("pg", pid, upstream_tools)

      assert {:upstream, ^pid, "query", _timeout} = ToolRegistry.resolve("pg::query")
    end

    test "resolve includes tool timeout in returned tuple" do
      upstream_tools = [
        %Tool{
          name: "slow_op",
          description: "Slow operation",
          input_schema: %{},
          origin: :native,
          timeout: 60_000
        }
      ]

      pid = self()
      ToolRegistry.register_upstream("custom", pid, upstream_tools)

      assert {:upstream, ^pid, "slow_op", 60_000} = ToolRegistry.resolve("custom::slow_op")
    end

    test "stores original tool name for stripping" do
      upstream_tools = [
        %Tool{name: "send_message", description: "Send", input_schema: %{}, origin: :native}
      ]

      pid = self()
      ToolRegistry.register_upstream("slack", pid, upstream_tools)

      assert {:upstream, ^pid, "send_message", _timeout} =
               ToolRegistry.resolve("slack::send_message")
    end
  end

  describe "deregister_upstream/1" do
    test "removes all tools with given prefix" do
      pid = self()

      upstream_tools = [
        %Tool{name: "tool1", description: "T1", input_schema: %{}, origin: :native},
        %Tool{name: "tool2", description: "T2", input_schema: %{}, origin: :native}
      ]

      ToolRegistry.register_upstream("test", pid, upstream_tools)
      assert ToolRegistry.count() == 2

      ToolRegistry.deregister_upstream("test")
      assert ToolRegistry.count() == 0
    end

    test "removes legacy path-like upstream tools" do
      tool = %Tool{
        name: "/github::search",
        description: "Search repositories",
        input_schema: %{},
        origin: {:upstream, "/github"},
        upstream_pid: self(),
        original_name: "search"
      }

      :ets.insert(:backplane_tools, {tool.name, tool})

      ToolRegistry.deregister_upstream("/github")
      assert ToolRegistry.list_all() == []
    end

    test "removes legacy path-like upstream tools by normalized prefix" do
      tool = %Tool{
        name: "/github::search",
        description: "Search repositories",
        input_schema: %{},
        origin: {:upstream, "/github"},
        upstream_pid: self(),
        original_name: "search"
      }

      :ets.insert(:backplane_tools, {tool.name, tool})

      ToolRegistry.deregister_upstream("github")
      assert ToolRegistry.list_all() == []
    end

    test "leaves other prefixes intact" do
      pid = self()

      tools_a = [%Tool{name: "t1", description: "T", input_schema: %{}, origin: :native}]
      tools_b = [%Tool{name: "t1", description: "T", input_schema: %{}, origin: :native}]

      ToolRegistry.register_upstream("a", pid, tools_a)
      ToolRegistry.register_upstream("b", pid, tools_b)
      assert ToolRegistry.count() == 2

      ToolRegistry.deregister_upstream("a")
      assert ToolRegistry.count() == 1
      assert {:upstream, ^pid, "t1", _timeout} = ToolRegistry.resolve("b::t1")
    end
  end

  describe "lookup/1" do
    test "returns tool struct for registered tool" do
      tool = sample_tool("test::lookup")
      ToolRegistry.register_native(tool)

      result = ToolRegistry.lookup("test::lookup")
      assert %Tool{name: "test::lookup"} = result
    end

    test "returns nil for unregistered tool" do
      assert ToolRegistry.lookup("nonexistent::tool") == nil
    end
  end

  describe "search/2" do
    test "finds tools by name substring" do
      ToolRegistry.register_native(sample_tool("git::repo-tree", description: "List files"))
      ToolRegistry.register_native(sample_tool("docs::query", description: "Search docs"))

      results = ToolRegistry.search("repo")
      assert length(results) == 1
      assert hd(results).name == "git::repo-tree"
    end

    test "finds tools by description substring" do
      ToolRegistry.register_native(sample_tool("git::tree", description: "List files in repo"))
      ToolRegistry.register_native(sample_tool("docs::query", description: "Search docs"))

      results = ToolRegistry.search("files")
      assert length(results) == 1
      assert hd(results).name == "git::tree"
    end

    test "respects limit option" do
      for i <- 1..5 do
        ToolRegistry.register_native(sample_tool("test::tool_#{i}", description: "Test tool"))
      end

      results = ToolRegistry.search("test", limit: 3)
      assert length(results) == 3
    end
  end
end
