defmodule BackplaneMemory.ServiceTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Memory
  alias BackplaneMemory.Service

  describe "tools/0" do
    test "exposes memory::* tools with handler functions" do
      names = Enum.map(Service.tools(), & &1.name)

      assert "memory::remember" in names
      assert "memory::recall" in names
      assert "memory::list" in names
      assert "memory::forget" in names
      assert "memory::stats" in names

      for tool <- Service.tools() do
        assert is_function(tool.handler, 1)
        assert is_binary(tool.description)
        assert is_map(tool.input_schema)
      end
    end

    test "prefix is \"memory\"", do: assert(Service.prefix() == "memory")
  end

  describe "handle_remember/1" do
    test "persists a memory and returns id, scope, memory_type" do
      args = %{
        "content" => "London is in the UK.",
        "agent_id" => "a",
        "host_id" => "h",
        "scope" => "geo"
      }

      assert {:ok, %{id: id, scope: "geo", memory_type: "semantic"}} =
               Service.handle_remember(args)

      assert is_binary(id)
    end

    test "returns changeset error when required fields are missing" do
      assert {:error, msg} = Service.handle_remember(%{"content" => "x"})
      assert msg =~ "agent_id" or msg =~ "host_id"
    end

    test "returns descriptive error when content is missing" do
      assert {:error, _} = Service.handle_remember(%{"agent_id" => "a"})
    end
  end

  describe "handle_recall/1" do
    test "falls back to text search when embedding is not configured" do
      {:ok, mem} =
        Memory.remember("service recall fallback",
          agent_id: "a",
          host_id: "h",
          scope: "service"
        )

      assert {:ok, %{results: [%{id: id}]}} =
               Service.handle_recall(%{
                 "query" => "service recall",
                 "limit" => 5,
                 "scope" => "service"
               })

      assert id == mem.id
    end

    test "returns error when query is missing" do
      assert {:error, _} = Service.handle_recall(%{})
    end
  end

  describe "handle_list/1" do
    test "returns memories with id, content, scope" do
      {:ok, _} = Memory.remember("Tokyo is in Japan.", agent_id: "a", host_id: "h")

      assert {:ok, %{results: [%{id: _, content: _, scope: _}]}} =
               Service.handle_list(%{"q" => "Tokyo"})
    end
  end

  describe "handle_forget/1" do
    test "soft-deletes a memory" do
      {:ok, mem} = Memory.remember("Berlin is in Germany.", agent_id: "a", host_id: "h")
      assert {:ok, %{id: id, status: "deleted"}} = Service.handle_forget(%{"id" => mem.id})
      assert id == mem.id
      assert {:error, :not_found} = Memory.get(mem.id)
    end

    test "returns error for unknown id" do
      assert {:error, "memory not found"} =
               Service.handle_forget(%{"id" => Ecto.UUID.generate()})
    end
  end

  describe "handle_stats/1" do
    test "returns stats grouped by memory_type" do
      {:ok, _} = Memory.remember("s1", agent_id: "a", host_id: "h", type: "semantic")
      assert {:ok, %{stats: stats}} = Service.handle_stats(%{})
      assert Enum.any?(stats, &(&1.memory_type == "semantic"))
    end
  end

  describe "enabled?/0" do
    test "false by default (opt-in via services.memory.enabled)" do
      refute Service.enabled?()
    end
  end
end
