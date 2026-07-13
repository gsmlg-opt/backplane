defmodule Backplane.Memory.ServiceToolsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories, Service}

  @extended_tool_names ~w(
    memory::access_log
    memory::consolidate
    memory::enrich
    memory::graph_query
    memory::graph_stats
    memory::slot_list
    memory::slot_read
    memory::slot_write
    memory::verify
  )

  @full_tool_contracts Map.new([
                         {"memory::access_log",
                          %{
                            "properties" => %{"memory_id" => %{"type" => "string"}},
                            "required" => ["memory_id"],
                            "type" => "object"
                          }},
                         {"memory::action_create",
                          %{
                            "properties" => %{
                              "created_by" => %{"type" => "string"},
                              "description" => %{"type" => "string"},
                              "edges" => %{
                                "items" => %{
                                  "properties" => %{
                                    "edge_type" => %{"type" => "string"},
                                    "source_id" => %{"type" => "string"},
                                    "target_id" => %{"type" => "string"}
                                  },
                                  "required" => ["source_id", "target_id", "edge_type"],
                                  "type" => "object"
                                },
                                "type" => "array"
                              },
                              "priority" => %{"default" => 0, "type" => "integer"},
                              "project" => %{"type" => "string"},
                              "tags" => %{
                                "items" => %{"type" => "string"},
                                "type" => "array"
                              },
                              "title" => %{"type" => "string"}
                            },
                            "required" => ["title"],
                            "type" => "object"
                          }},
                         {"memory::action_update",
                          %{
                            "properties" => %{
                              "action_id" => %{"type" => "string"},
                              "status" => %{
                                "enum" => [
                                  "pending",
                                  "in_progress",
                                  "done",
                                  "blocked",
                                  "cancelled"
                                ],
                                "type" => "string"
                              }
                            },
                            "required" => ["action_id", "status"],
                            "type" => "object"
                          }},
                         {"memory::audit",
                          %{
                            "properties" => %{
                              "actor" => %{"type" => "string"},
                              "limit" => %{"default" => 50, "type" => "integer"},
                              "offset" => %{"default" => 0, "type" => "integer"},
                              "operation" => %{"type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::compress_file",
                          %{
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "file_path" => %{"type" => "string"},
                              "host_id" => %{"type" => "string"}
                            },
                            "required" => ["file_path", "agent_id", "host_id"],
                            "type" => "object"
                          }},
                         {"memory::consolidate",
                          %{
                            "properties" => %{"session_id" => %{"type" => "string"}},
                            "required" => ["session_id"],
                            "type" => "object"
                          }},
                         {"memory::diagnose", %{"properties" => %{}, "type" => "object"}},
                         {"memory::enrich",
                          %{
                            "properties" => %{
                              "memory_id" => %{"type" => "string"},
                              "metadata" => %{"type" => "object"},
                              "tags" => %{
                                "items" => %{"type" => "string"},
                                "type" => "array"
                              }
                            },
                            "required" => ["memory_id"],
                            "type" => "object"
                          }},
                         {"memory::expand_query",
                          %{
                            "properties" => %{
                              "query" => %{
                                "description" => "Query to expand",
                                "type" => "string"
                              }
                            },
                            "required" => ["query"],
                            "type" => "object"
                          }},
                         {"memory::export",
                          %{
                            "properties" => %{
                              "scope" => %{"default" => "global", "type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::facet_query",
                          %{
                            "properties" => %{
                              "facets" => %{
                                "items" => %{
                                  "properties" => %{
                                    "dimension" => %{"type" => "string"},
                                    "value" => %{"type" => "string"}
                                  },
                                  "type" => "object"
                                },
                                "type" => "array"
                              },
                              "limit" => %{"default" => 20, "type" => "integer"}
                            },
                            "required" => ["facets"],
                            "type" => "object"
                          }},
                         {"memory::facet_tag",
                          %{
                            "properties" => %{
                              "facets" => %{
                                "items" => %{
                                  "properties" => %{
                                    "dimension" => %{"type" => "string"},
                                    "value" => %{"type" => "string"}
                                  },
                                  "required" => ["dimension", "value"],
                                  "type" => "object"
                                },
                                "type" => "array"
                              },
                              "memory_id" => %{"type" => "string"}
                            },
                            "required" => ["memory_id", "facets"],
                            "type" => "object"
                          }},
                         {"memory::file_history",
                          %{
                            "properties" => %{
                              "exclude_session" => %{"type" => "string"},
                              "files" => %{
                                "items" => %{"type" => "string"},
                                "type" => "array"
                              },
                              "limit" => %{"default" => 50, "type" => "integer"}
                            },
                            "required" => ["files"],
                            "type" => "object"
                          }},
                         {"memory::forget",
                          %{
                            "properties" => %{"id" => %{"type" => "string"}},
                            "required" => ["id"],
                            "type" => "object"
                          }},
                         {"memory::frontier",
                          %{
                            "properties" => %{"project" => %{"type" => "string"}},
                            "type" => "object"
                          }},
                         {"memory::governance_delete",
                          %{
                            "properties" => %{
                              "actor" => %{"type" => "string"},
                              "memory_id" => %{"type" => "string"},
                              "reason" => %{"type" => "string"}
                            },
                            "required" => ["memory_id"],
                            "type" => "object"
                          }},
                         {"memory::graph_query",
                          %{
                            "properties" => %{
                              "depth" => %{"default" => 2, "type" => "integer"},
                              "entity" => %{"type" => "string"},
                              "relation" => %{"type" => "string"}
                            },
                            "required" => ["entity"],
                            "type" => "object"
                          }},
                         {"memory::graph_stats", %{"properties" => %{}, "type" => "object"}},
                         {"memory::heal", %{"properties" => %{}, "type" => "object"}},
                         {"memory::lease",
                          %{
                            "properties" => %{
                              "action_id" => %{"type" => "string"},
                              "agent_id" => %{"type" => "string"},
                              "ttl_seconds" => %{"default" => 300, "type" => "integer"}
                            },
                            "required" => ["action_id", "agent_id"],
                            "type" => "object"
                          }},
                         {"memory::list",
                          %{
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "limit" => %{"default" => 50, "type" => "integer"},
                              "offset" => %{"default" => 0, "type" => "integer"},
                              "q" => %{
                                "description" => "Substring match on content",
                                "type" => "string"
                              },
                              "scope" => %{"type" => "string"},
                              "tag" => %{"type" => "string"},
                              "type" => %{"type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::next",
                          %{
                            "properties" => %{"project" => %{"type" => "string"}},
                            "type" => "object"
                          }},
                         {"memory::patterns",
                          %{
                            "properties" => %{
                              "limit" => %{"default" => 10, "type" => "integer"},
                              "session_id" => %{"type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::profile",
                          %{
                            "properties" => %{
                              "project" => %{
                                "description" => "Project path / scope key",
                                "type" => "string"
                              }
                            },
                            "required" => ["project"],
                            "type" => "object"
                          }},
                         {"memory::profile_refresh",
                          %{
                            "properties" => %{"project" => %{"type" => "string"}},
                            "required" => ["project"],
                            "type" => "object"
                          }},
                         {"memory::recall",
                          %{
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "host_id" => %{"type" => "string"},
                              "limit" => %{"default" => 10, "type" => "integer"},
                              "query" => %{
                                "description" => "Query text",
                                "type" => "string"
                              },
                              "scope" => %{"type" => "string"},
                              "tag" => %{"type" => "string"}
                            },
                            "required" => ["query"],
                            "type" => "object"
                          }},
                         {"memory::relations",
                          %{
                            "properties" => %{
                              "depth" => %{"default" => 1, "type" => "integer"},
                              "entity" => %{"type" => "string"}
                            },
                            "required" => ["entity"],
                            "type" => "object"
                          }},
                         {"memory::remember",
                          %{
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "client_id" => %{"type" => "string"},
                              "content" => %{
                                "description" => "Memory text",
                                "type" => "string"
                              },
                              "host_id" => %{"type" => "string"},
                              "metadata" => %{"type" => "object"},
                              "scope" => %{
                                "default" => "global",
                                "description" => "Scope key",
                                "type" => "string"
                              },
                              "session_id" => %{"type" => "string"},
                              "tags" => %{
                                "items" => %{"type" => "string"},
                                "type" => "array"
                              },
                              "type" => %{
                                "default" => "semantic",
                                "description" => "working | episodic | semantic | procedural",
                                "type" => "string"
                              }
                            },
                            "required" => ["content", "agent_id", "host_id"],
                            "type" => "object"
                          }},
                         {"memory::sessions",
                          %{
                            "properties" => %{
                              "limit" => %{"default" => 20, "type" => "integer"},
                              "project" => %{"type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::signal_read",
                          %{
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "limit" => %{"default" => 20, "type" => "integer"},
                              "topic" => %{"type" => "string"}
                            },
                            "required" => ["agent_id"],
                            "type" => "object"
                          }},
                         {"memory::signal_send",
                          %{
                            "properties" => %{
                              "payload" => %{"type" => "object"},
                              "recipient_agent_id" => %{"type" => "string"},
                              "sender_agent_id" => %{"type" => "string"},
                              "topic" => %{"type" => "string"}
                            },
                            "required" => [
                              "sender_agent_id",
                              "recipient_agent_id",
                              "topic"
                            ],
                            "type" => "object"
                          }},
                         {"memory::slot_list", %{"properties" => %{}, "type" => "object"}},
                         {"memory::slot_read",
                          %{
                            "properties" => %{"name" => %{"type" => "string"}},
                            "required" => ["name"],
                            "type" => "object"
                          }},
                         {"memory::slot_write",
                          %{
                            "properties" => %{
                              "content" => %{"type" => "string"},
                              "name" => %{"type" => "string"},
                              "updated_by" => %{"type" => "string"}
                            },
                            "required" => ["name", "content"],
                            "type" => "object"
                          }},
                         {"memory::smart_search",
                          %{
                            "properties" => %{
                              "limit" => %{"default" => 5, "type" => "integer"},
                              "query" => %{"type" => "string"}
                            },
                            "required" => ["query"],
                            "type" => "object"
                          }},
                         {"memory::stats", %{"properties" => %{}, "type" => "object"}},
                         {"memory::team_feed",
                          %{
                            "properties" => %{
                              "limit" => %{"default" => 20, "type" => "integer"},
                              "team_id" => %{"type" => "string"}
                            },
                            "required" => ["team_id"],
                            "type" => "object"
                          }},
                         {"memory::team_share",
                          %{
                            "properties" => %{
                              "memory_id" => %{"type" => "string"},
                              "team_id" => %{"type" => "string"}
                            },
                            "required" => ["memory_id", "team_id"],
                            "type" => "object"
                          }},
                         {"memory::timeline",
                          %{
                            "properties" => %{
                              "limit" => %{"default" => 50, "type" => "integer"},
                              "session_id" => %{"type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::verify",
                          %{
                            "properties" => %{"memory_id" => %{"type" => "string"}},
                            "required" => ["memory_id"],
                            "type" => "object"
                          }}
                       ])

  @core_tool_contracts Map.drop(@full_tool_contracts, @extended_tool_names)

  setup do
    previous = :ets.lookup(:backplane_settings, "memory.tools")

    on_exit(fn ->
      case previous do
        [] -> :ets.delete(:backplane_settings, "memory.tools")
        rows -> :ets.insert(:backplane_settings, rows)
      end
    end)

    :ok
  end

  defp set_tool_mode(mode), do: :ets.insert(:backplane_settings, {"memory.tools", mode})
  defp contracts(tools), do: Map.new(tools, &{&1.name, &1.input_schema})

  # ──────────────────────────────────────────────
  # tools/0 gating
  # ──────────────────────────────────────────────

  describe "tools/0 — core tools (always available)" do
    test "returns the exact 31 core names and input schemas" do
      set_tool_mode("core")
      tools = Service.tools()
      names = Enum.map(tools, & &1.name)

      assert length(tools) == 31
      assert length(Enum.uniq(names)) == 31
      assert contracts(tools) == @core_tool_contracts
      assert map_size(@core_tool_contracts) == 31
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

    test "consolidate remains extended-only" do
      set_tool_mode("core")
      refute Enum.any?(Service.tools(), &(&1.name == "memory::consolidate"))

      set_tool_mode("all")
      assert Enum.any?(Service.tools(), &(&1.name == "memory::consolidate"))
    end
  end

  describe "tools/0 — extended tools (memory.tools = 'all')" do
    test "returns the exact 40 full names and input schemas" do
      set_tool_mode("all")
      tools = Service.tools()
      names = Enum.map(tools, & &1.name)

      assert length(tools) == 40
      assert length(Enum.uniq(names)) == 40
      assert contracts(tools) == @full_tool_contracts
      assert map_size(@full_tool_contracts) == 40
    end
  end

  # ──────────────────────────────────────────────
  # handle_governance_delete/1
  # ──────────────────────────────────────────────

  describe "handle_governance_delete/1" do
    test "soft-deletes a memory and writes an audit entry" do
      {:ok, mem} =
        Memories.remember("temporary fact", agent_id: "gov_agent", host_id: "gov_host")

      assert {:ok, result} =
               Service.handle_governance_delete(%{
                 "memory_id" => mem.id,
                 "actor" => "admin",
                 "reason" => "test cleanup"
               })

      assert result.status == "soft_deleted"
      assert result.memory_id == mem.id

      # Memory should be soft-deleted
      assert {:error, :not_found} = Memories.get(mem.id)

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
