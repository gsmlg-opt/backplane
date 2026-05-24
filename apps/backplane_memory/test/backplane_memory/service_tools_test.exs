defmodule BackplaneMemory.ServiceToolsTest do
  use BackplaneMemory.DataCase, async: false

  alias BackplaneMemory.{Audit, Memory, Service}

  # ──────────────────────────────────────────────
  # tools/0 gating
  # ──────────────────────────────────────────────

  describe "tools/0 — core tools (always available)" do
    test "returns at least 15 tools when memory.tools is not 'all'" do
      # Ensure the setting is NOT "all"
      Backplane.Settings.set("memory.tools", "core")
      tools = Service.tools()
      assert length(tools) >= 15
    end

    test "all returned tools have required fields" do
      tools = Service.tools()

      for tool <- tools do
        assert is_binary(tool.name), "name must be a string: #{inspect(tool)}"
        assert is_binary(tool.description), "description must be a string for #{tool.name}"
        assert is_map(tool.input_schema), "input_schema must be a map for #{tool.name}"
        assert is_function(tool.handler, 1), "handler must be arity-1 fun for #{tool.name}"
      end
    end

    test "core tools include smart_search, sessions, patterns, governance_delete, diagnose, heal" do
      Backplane.Settings.set("memory.tools", "core")
      names = Enum.map(Service.tools(), & &1.name)
      assert "memory::smart_search" in names
      assert "memory::sessions" in names
      assert "memory::patterns" in names
      assert "memory::governance_delete" in names
      assert "memory::diagnose" in names
      assert "memory::heal" in names
    end
  end

  describe "tools/0 — extended tools (memory.tools = 'all')" do
    test "returns at least 37 tools when memory.tools is 'all'" do
      Backplane.Settings.set("memory.tools", "all")
      tools = Service.tools()
      assert length(tools) >= 37
    end

    test "extended tools include slot_read, slot_write, slot_list, graph_query, graph_stats, verify, enrich, access_log, consolidate" do
      Backplane.Settings.set("memory.tools", "all")
      names = Enum.map(Service.tools(), & &1.name)
      assert "memory::slot_read" in names
      assert "memory::slot_write" in names
      assert "memory::slot_list" in names
      assert "memory::graph_query" in names
      assert "memory::graph_stats" in names
      assert "memory::verify" in names
      assert "memory::enrich" in names
      assert "memory::access_log" in names
      assert "memory::consolidate" in names
    end
  end

  # ──────────────────────────────────────────────
  # handle_governance_delete/1
  # ──────────────────────────────────────────────

  describe "handle_governance_delete/1" do
    test "soft-deletes a memory and writes an audit entry" do
      {:ok, mem} =
        Memory.remember("temporary fact", agent_id: "gov_agent", host_id: "gov_host")

      assert {:ok, result} =
               Service.handle_governance_delete(%{
                 "memory_id" => mem.id,
                 "actor" => "admin",
                 "reason" => "test cleanup"
               })

      assert result.status == "soft_deleted"
      assert result.memory_id == mem.id

      # Memory should be soft-deleted
      assert {:error, :not_found} = Memory.get(mem.id)

      # Audit entry should exist
      entries = Audit.list(operation: "governance_delete")
      assert Enum.any?(entries, fn e -> e.target_ids["memory_id"] == mem.id end)
    end

    test "returns error for unknown memory_id" do
      assert {:error, "memory not found"} =
               Service.handle_governance_delete(%{
                 "memory_id" => Ecto.UUID.generate(),
                 "actor" => "admin"
               })
    end

    test "returns error when memory_id is missing" do
      assert {:error, _} = Service.handle_governance_delete(%{"actor" => "admin"})
    end
  end

  # ──────────────────────────────────────────────
  # resources/0 and prompts/0
  # ──────────────────────────────────────────────

  describe "resources/0" do
    test "returns 5 resource definitions with required fields" do
      resources = Service.resources()
      assert length(resources) == 5

      for r <- resources do
        assert is_binary(r.uri)
        assert is_binary(r.name)
        assert is_binary(r.description)
        assert is_binary(r.mime_type)
      end
    end

    test "memory://status returns JSON with status ok" do
      assert {:ok, json} = Service.read_resource("memory://status")
      assert %{"status" => "ok"} = Jason.decode!(json)
    end

    test "unknown URI returns {:error, :not_found}" do
      assert {:error, :not_found} = Service.read_resource("memory://does_not_exist")
    end
  end

  describe "prompts/0" do
    test "returns 3 prompt definitions" do
      prompts = Service.prompts()
      assert length(prompts) == 3
      names = Enum.map(prompts, & &1.name)
      assert "recall_context" in names
      assert "session_handoff" in names
      assert "detect_patterns" in names
    end

    test "get_prompt/2 returns handoff message for session_handoff" do
      assert {:ok, messages} = Service.get_prompt("session_handoff", %{"session_id" => "abc"})
      assert [%{role: "user", content: content}] = messages
      assert content =~ "abc"
    end

    test "get_prompt/2 returns {:error, :not_found} for unknown prompt" do
      assert {:error, :not_found} = Service.get_prompt("nonexistent", %{})
    end
  end
end
