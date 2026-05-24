defmodule BackplaneMemory.Service do
  @moduledoc "Managed MCP service exposing memory::* tools."

  @behaviour Backplane.Services.ManagedService

  import Ecto.Query

  alias BackplaneMemory.Coordination.{Action, Lease, Signal}
  alias BackplaneMemory.Memories.{Profiles, Search}
  alias BackplaneMemory.Memory

  @impl true
  def prefix, do: "memory"

  @impl true
  def enabled?, do: Backplane.Settings.get("services.memory.enabled") == true

  @impl true
  def tools do
    core_tools() ++ extended_tools()
  end

  defp core_tools do
    [
      %{
        name: "memory::facet_tag",
        description: "Tag an existing memory with dimension:value facets.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "facets" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "dimension" => %{"type" => "string"},
                  "value" => %{"type" => "string"}
                },
                "required" => ["dimension", "value"]
              }
            }
          },
          "required" => ["memory_id", "facets"]
        },
        handler: &handle_facet_tag/1
      },
      %{
        name: "memory::facet_query",
        description: "Query memories by facet filter (AND across dimensions).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "facets" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "dimension" => %{"type" => "string"},
                  "value" => %{"type" => "string"}
                }
              }
            },
            "limit" => %{"type" => "integer", "default" => 20}
          },
          "required" => ["facets"]
        },
        handler: &handle_facet_query/1
      },
      %{
        name: "memory::remember",
        description: "Persist a memory entry. Deduplicates by content+scope over 24h.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "Memory text"},
            "type" => %{
              "type" => "string",
              "description" => "working | episodic | semantic | procedural",
              "default" => "semantic"
            },
            "scope" => %{
              "type" => "string",
              "description" => "Scope key",
              "default" => "global"
            },
            "agent_id" => %{"type" => "string"},
            "host_id" => %{"type" => "string"},
            "client_id" => %{"type" => "string"},
            "session_id" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "metadata" => %{"type" => "object"}
          },
          "required" => ["content", "agent_id", "host_id"]
        },
        handler: &handle_remember/1
      },
      %{
        name: "memory::recall",
        description: "Vector-search memories by query using cosine similarity.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Query text"},
            "limit" => %{"type" => "integer", "default" => 10},
            "scope" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "host_id" => %{"type" => "string"},
            "tag" => %{"type" => "string"}
          },
          "required" => ["query"]
        },
        handler: &handle_recall/1
      },
      %{
        name: "memory::list",
        description: "List memories with optional filters, ordered by most recent.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string"},
            "scope" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "tag" => %{"type" => "string"},
            "q" => %{"type" => "string", "description" => "Substring match on content"},
            "limit" => %{"type" => "integer", "default" => 50},
            "offset" => %{"type" => "integer", "default" => 0}
          }
        },
        handler: &handle_list/1
      },
      %{
        name: "memory::forget",
        description: "Soft-delete a memory by id.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        },
        handler: &handle_forget/1
      },
      %{
        name: "memory::stats",
        description: "Return counts grouped by memory_type.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: &handle_stats/1
      },
      %{
        name: "memory::profile",
        description: "Get the project intelligence profile (top concepts, files, patterns).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project" => %{"type" => "string", "description" => "Project path / scope key"}
          },
          "required" => ["project"]
        },
        handler: &handle_profile/1
      },
      %{
        name: "memory::profile_refresh",
        description: "Trigger an async rebuild of the project profile.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project" => %{"type" => "string"}
          },
          "required" => ["project"]
        },
        handler: &handle_profile_refresh/1
      },
      %{
        name: "memory::expand_query",
        description: "Expand a query into alternative phrasings for broader search coverage.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Query to expand"}
          },
          "required" => ["query"]
        },
        handler: &handle_expand_query/1
      },
      %{
        name: "memory::file_history",
        description: "Return observations referencing the given file paths.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "files" => %{"type" => "array", "items" => %{"type" => "string"}},
            "exclude_session" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 50}
          },
          "required" => ["files"]
        },
        handler: &handle_file_history/1
      },
      %{
        name: "memory::team_share",
        description: "Share a memory with a team by setting namespace to team:<team_id>.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "team_id" => %{"type" => "string"}
          },
          "required" => ["memory_id", "team_id"]
        },
        handler: &handle_team_share/1
      },
      %{
        name: "memory::team_feed",
        description: "Return recent memories shared with a team, newest first.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "team_id" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 20}
          },
          "required" => ["team_id"]
        },
        handler: &handle_team_feed/1
      },
      %{
        name: "memory::lease",
        description: "Acquire an exclusive lease on an action_id for distributed coordination.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action_id" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "ttl_seconds" => %{"type" => "integer", "default" => 300}
          },
          "required" => ["action_id", "agent_id"]
        },
        handler: &handle_lease/1
      },
      %{
        name: "memory::signal_send",
        description: "Send a signal from one agent to another.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "sender_agent_id" => %{"type" => "string"},
            "recipient_agent_id" => %{"type" => "string"},
            "topic" => %{"type" => "string"},
            "payload" => %{"type" => "object"}
          },
          "required" => ["sender_agent_id", "recipient_agent_id", "topic"]
        },
        handler: &handle_signal_send/1
      },
      %{
        name: "memory::signal_read",
        description: "Read and mark-read unread signals for an agent.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string"},
            "topic" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 20}
          },
          "required" => ["agent_id"]
        },
        handler: &handle_signal_read/1
      },
      %{
        name: "memory::action_create",
        description: "Create an action item with optional dependency edges.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "priority" => %{"type" => "integer", "default" => 0},
            "project" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "created_by" => %{"type" => "string"},
            "edges" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "source_id" => %{"type" => "string"},
                  "target_id" => %{"type" => "string"},
                  "edge_type" => %{"type" => "string"}
                },
                "required" => ["source_id", "target_id", "edge_type"]
              }
            }
          },
          "required" => ["title"]
        },
        handler: &handle_action_create/1
      },
      %{
        name: "memory::action_update",
        description: "Update the status of an action.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action_id" => %{"type" => "string"},
            "status" => %{
              "type" => "string",
              "enum" => ["pending", "in_progress", "done", "blocked", "cancelled"]
            }
          },
          "required" => ["action_id", "status"]
        },
        handler: &handle_action_update/1
      },
      %{
        name: "memory::frontier",
        description: "Return actions with no pending prerequisites, sorted by priority.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project" => %{"type" => "string"}
          }
        },
        handler: &handle_frontier/1
      },
      %{
        name: "memory::next",
        description: "Return the single highest-priority unblocked action.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project" => %{"type" => "string"}
          }
        },
        handler: &handle_next/1
      },
      %{
        name: "memory::smart_search",
        description: "Hybrid search (vector + FTS + graph) returning top-N results.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 5}
          },
          "required" => ["query"]
        },
        handler: &handle_smart_search/1
      },
      %{
        name: "memory::sessions",
        description: "List memory sessions with id, project, observation count, and times.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "default" => 20},
            "project" => %{"type" => "string"}
          }
        },
        handler: &handle_sessions/1
      },
      %{
        name: "memory::patterns",
        description: "Group observations by tool_name and return top tools and file patterns.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 10}
          }
        },
        handler: &handle_patterns/1
      },
      %{
        name: "memory::timeline",
        description: "Observations ordered by time, grouped by session.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 50}
          }
        },
        handler: &handle_timeline/1
      },
      %{
        name: "memory::export",
        description: "JSON export of all non-deleted memories for a scope.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "scope" => %{"type" => "string", "default" => "global"}
          }
        },
        handler: &handle_export/1
      },
      %{
        name: "memory::relations",
        description: "Return graph edges for a given entity name.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "entity" => %{"type" => "string"},
            "depth" => %{"type" => "integer", "default" => 1}
          },
          "required" => ["entity"]
        },
        handler: &handle_relations/1
      },
      %{
        name: "memory::compress_file",
        description: "Summarise all observations for a file path into a single semantic memory.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "file_path" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "host_id" => %{"type" => "string"}
          },
          "required" => ["file_path", "agent_id", "host_id"]
        },
        handler: &handle_compress_file/1
      },
      %{
        name: "memory::audit",
        description: "Paginated audit log of governance operations.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "default" => 50},
            "offset" => %{"type" => "integer", "default" => 0},
            "operation" => %{"type" => "string"},
            "actor" => %{"type" => "string"}
          }
        },
        handler: &handle_audit/1
      },
      %{
        name: "memory::governance_delete",
        description:
          "Soft-delete a memory with audit trail. Hard-delete only if memory.hard_delete_enabled=true.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "actor" => %{"type" => "string"},
            "reason" => %{"type" => "string"}
          },
          "required" => ["memory_id"]
        },
        handler: &handle_governance_delete/1
      },
      %{
        name: "memory::diagnose",
        description: "System health: circuit breaker state, queue depth, and memory stats.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: &handle_diagnose/1
      },
      %{
        name: "memory::heal",
        description: "Clear orphaned leases and emit a heal event.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: &handle_heal/1
      }
    ]
  end

  defp extended_tools do
    if Backplane.Settings.get("memory.tools") == "all" do
      [
        %{
          name: "memory::graph_query",
          description: "BFS traversal over the knowledge graph from a named entity.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "entity" => %{"type" => "string"},
              "depth" => %{"type" => "integer", "default" => 2},
              "relation" => %{"type" => "string"}
            },
            "required" => ["entity"]
          },
          handler: &handle_graph_query/1
        },
        %{
          name: "memory::graph_stats",
          description: "Return knowledge graph node and edge counts grouped by type/relation.",
          input_schema: %{"type" => "object", "properties" => %{}},
          handler: &handle_graph_stats/1
        },
        %{
          name: "memory::consolidate",
          description: "Enqueue a consolidation job for a session.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "session_id" => %{"type" => "string"}
            },
            "required" => ["session_id"]
          },
          handler: &handle_consolidate/1
        },
        %{
          name: "memory::verify",
          description: "Check that a memory ID exists and is non-deleted.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "memory_id" => %{"type" => "string"}
            },
            "required" => ["memory_id"]
          },
          handler: &handle_verify/1
        },
        %{
          name: "memory::slot_read",
          description: "Read a named memory slot.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"}
            },
            "required" => ["name"]
          },
          handler: &handle_slot_read/1
        },
        %{
          name: "memory::slot_write",
          description: "Write content to a named memory slot.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "content" => %{"type" => "string"},
              "updated_by" => %{"type" => "string"}
            },
            "required" => ["name", "content"]
          },
          handler: &handle_slot_write/1
        },
        %{
          name: "memory::slot_list",
          description: "List all memory slots and their content.",
          input_schema: %{"type" => "object", "properties" => %{}},
          handler: &handle_slot_list/1
        },
        %{
          name: "memory::enrich",
          description: "Add tags or metadata to an existing memory.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "memory_id" => %{"type" => "string"},
              "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
              "metadata" => %{"type" => "object"}
            },
            "required" => ["memory_id"]
          },
          handler: &handle_enrich/1
        },
        %{
          name: "memory::access_log",
          description: "Return access history for a memory (access_count and accessed_at).",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "memory_id" => %{"type" => "string"}
            },
            "required" => ["memory_id"]
          },
          handler: &handle_access_log/1
        }
      ]
    else
      []
    end
  end

  # ──────────────────────────────────────────────
  # Resources
  # ──────────────────────────────────────────────

  def resources do
    [
      %{
        uri: "memory://status",
        name: "Memory Status",
        description: "Health, session count, memory count",
        mime_type: "application/json"
      },
      %{
        uri: "memory://memories/latest",
        name: "Latest Memories",
        description: "Latest 10 active memories",
        mime_type: "application/json"
      },
      %{
        uri: "memory://graph/stats",
        name: "Graph Stats",
        description: "Knowledge graph node and edge counts",
        mime_type: "application/json"
      },
      %{
        uri: "memory://sessions/active",
        name: "Active Sessions",
        description: "Currently active sessions",
        mime_type: "application/json"
      },
      %{
        uri: "memory://audit/recent",
        name: "Recent Audit",
        description: "Last 50 audit log entries",
        mime_type: "application/json"
      }
    ]
  end

  def read_resource("memory://status") do
    stats = Memory.stats()
    {:ok, Jason.encode!(%{status: "ok", memory_stats: stats})}
  end

  def read_resource("memory://memories/latest") do
    rows = Memory.list(limit: 10)

    {:ok,
     Jason.encode!(%{
       memories:
         Enum.map(
           rows,
           &Map.take(&1, [:id, :content, :memory_type, :scope, :inserted_at])
         )
     })}
  end

  def read_resource("memory://graph/stats") do
    {:ok, Jason.encode!(BackplaneMemory.Graph.stats())}
  end

  def read_resource("memory://sessions/active") do
    repo = Application.fetch_env!(:backplane_memory, :repo)

    sessions =
      repo.all(from(s in BackplaneMemory.Observations.Session, where: is_nil(s.ended_at)))

    {:ok,
     Jason.encode!(%{
       sessions: Enum.map(sessions, &Map.take(&1, [:session_id, :project, :started_at]))
     })}
  end

  def read_resource("memory://audit/recent") do
    entries = BackplaneMemory.Audit.list(limit: 50)
    {:ok, Jason.encode!(%{entries: entries})}
  end

  def read_resource(_uri), do: {:error, :not_found}

  # ──────────────────────────────────────────────
  # Prompts
  # ──────────────────────────────────────────────

  def prompts do
    [
      %{
        name: "recall_context",
        description: "Search memory and return formatted context for the current task",
        arguments: [%{name: "query", description: "What to search for", required: true}]
      },
      %{
        name: "session_handoff",
        description: "Build a handoff summary for the current session",
        arguments: [
          %{name: "session_id", description: "Session to summarise", required: false}
        ]
      },
      %{
        name: "detect_patterns",
        description: "Analyse recent observations for recurring patterns",
        arguments: [%{name: "project", description: "Project scope", required: false}]
      }
    ]
  end

  def get_prompt("recall_context", %{"query" => query}) do
    case Search.hybrid_recall(query, limit: 5) do
      {:ok, results} ->
        content = Enum.map_join(results, "\n", fn r -> "- #{r.content}" end)
        {:ok, [%{role: "user", content: "Relevant memories:\n#{content}"}]}

      _ ->
        {:ok, [%{role: "user", content: "No relevant memories found."}]}
    end
  end

  def get_prompt("session_handoff", args) do
    session_id = Map.get(args, "session_id", "current")

    {:ok,
     [
       %{
         role: "user",
         content:
           "Session #{session_id} handoff: review your recent work and summarise key decisions and next steps."
       }
     ]}
  end

  def get_prompt("detect_patterns", _args) do
    {:ok,
     [
       %{
         role: "user",
         content:
           "Review recent observations and identify recurring patterns, common tools used, and frequent file paths."
       }
     ]}
  end

  def get_prompt(_, _), do: {:error, :not_found}

  # ──────────────────────────────────────────────
  # Existing handlers (unchanged)
  # ──────────────────────────────────────────────

  def handle_remember(%{"content" => content} = args) when is_binary(content) do
    opts = [
      type: args["type"] || "semantic",
      scope: args["scope"] || "global",
      agent_id: args["agent_id"] || "",
      host_id: args["host_id"] || "",
      client_id: args["client_id"],
      session_id: args["session_id"],
      tags: args["tags"] || [],
      metadata: args["metadata"] || %{}
    ]

    case Memory.remember(content, opts) do
      {:ok, mem} ->
        case args["facets"] do
          facets when is_list(facets) and facets != [] ->
            case BackplaneMemory.Facets.tag(mem.id, facets) do
              {:ok, _count} ->
                {:ok, %{id: mem.id, scope: mem.scope, memory_type: mem.memory_type}}

              {:error, {:unknown_dimension, dim}} ->
                {:error, "unknown facet dimension: #{dim}"}

              {:error, reason} ->
                {:error, inspect(reason)}
            end

          _ ->
            {:ok, %{id: mem.id, scope: mem.scope, memory_type: mem.memory_type}}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, format_changeset(changeset)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def handle_remember(_), do: {:error, "content is required and must be a string"}

  def handle_recall(%{"query" => query} = args) when is_binary(query) do
    opts =
      [limit: args["limit"] || 10]
      |> add_if(args, "scope", :scope)
      |> add_if(args, "agent_id", :agent_id)
      |> add_if(args, "host_id", :host_id)
      |> add_if(args, "tag", :tag)

    case args["facets"] do
      facets when is_list(facets) and facets != [] ->
        facet_ids = BackplaneMemory.Facets.query(facets)

        if facet_ids == [] do
          {:ok, %{results: []}}
        else
          case Search.recall(query, opts) do
            {:ok, results} ->
              id_set = MapSet.new(facet_ids)
              filtered = Enum.filter(results, fn r -> MapSet.member?(id_set, r.id) end)
              {:ok, %{results: filtered}}

            {:error, reason} ->
              {:error, inspect(reason)}
          end
        end

      _ ->
        case Search.recall(query, opts) do
          {:ok, results} -> {:ok, %{results: results}}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  def handle_recall(_), do: {:error, "query is required and must be a string"}

  def handle_list(args) when is_map(args) do
    opts =
      []
      |> add_if(args, "type", :type)
      |> add_if(args, "scope", :scope)
      |> add_if(args, "agent_id", :agent_id)
      |> add_if(args, "tag", :tag)
      |> add_if(args, "q", :q)
      |> Keyword.put(:limit, args["limit"] || 50)
      |> Keyword.put(:offset, args["offset"] || 0)

    rows = Memory.list(opts)

    {:ok,
     %{
       results:
         Enum.map(rows, fn r ->
           %{
             id: r.id,
             content: r.content,
             scope: r.scope,
             memory_type: r.memory_type,
             tags: r.tags,
             inserted_at: r.inserted_at
           }
         end)
     }}
  end

  def handle_forget(%{"id" => id}) when is_binary(id) do
    case Memory.forget(id) do
      :ok -> {:ok, %{id: id, status: "deleted"}}
      {:error, :not_found} -> {:error, "memory not found"}
    end
  end

  def handle_forget(_), do: {:error, "id is required and must be a string"}

  def handle_stats(_args), do: {:ok, %{stats: Memory.stats()}}

  def handle_profile(%{"project" => project}) when is_binary(project) do
    case Profiles.get_or_build(project) do
      {:ok, p} ->
        {:ok,
         %{
           project: p.project,
           top_concepts: p.top_concepts,
           top_files: p.top_files,
           patterns: p.patterns,
           session_count: p.session_count,
           total_observations: p.total_observations
         }}

      {:building, nil} ->
        {:ok, %{status: "building"}}
    end
  end

  def handle_profile(_), do: {:error, "project is required"}

  def handle_profile_refresh(%{"project" => project}) when is_binary(project) do
    BackplaneMemory.Workers.ProfileBuildWorker.enqueue(project)
    {:ok, %{status: "queued", project: project}}
  end

  def handle_profile_refresh(_), do: {:error, "project is required"}

  def handle_expand_query(%{"query" => query}) when is_binary(query) do
    llm_module = Application.get_env(:backplane_memory, :llm_module, BackplaneMemory.LLM)

    case llm_module.expand_query(query) do
      {:ok, expansions} -> {:ok, %{query: query, expansions: expansions}}
      {:skip, _} -> {:ok, %{query: query, expansions: [query], note: "LLM not configured"}}
    end
  end

  def handle_expand_query(_), do: {:error, "query is required"}

  def handle_file_history(%{"files" => files} = args) when is_list(files) do
    opts =
      [limit: args["limit"] || 50]
      |> then(fn o ->
        case args["exclude_session"] do
          s when is_binary(s) and s != "" -> Keyword.put(o, :exclude_session, s)
          _ -> o
        end
      end)

    rows = BackplaneMemory.Observations.file_history(files, opts)

    results =
      Enum.map(rows, fn o ->
        %{
          id: o.id,
          session_id: o.session_id,
          tool_name: o.tool_name,
          content: o.content,
          created_at: o.created_at
        }
      end)

    {:ok, %{results: results}}
  end

  def handle_file_history(_), do: {:error, "files is required and must be an array"}

  def handle_facet_tag(%{"memory_id" => id, "facets" => facets}) do
    case BackplaneMemory.Facets.tag(id, facets) do
      {:ok, count} -> {:ok, %{tagged: count}}
      {:error, {:unknown_dimension, dim}} -> {:error, "unknown facet dimension: #{dim}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_facet_tag(_), do: {:error, "memory_id and facets are required"}

  def handle_facet_query(%{"facets" => facets} = args) when is_list(facets) do
    limit = args["limit"] || 20
    memory_ids = BackplaneMemory.Facets.query(facets)

    if memory_ids == [] do
      {:ok, %{results: []}}
    else
      repo = Application.fetch_env!(:backplane_memory, :repo)

      rows =
        repo.all(
          from(m in BackplaneMemory.Memories.Memory,
            where: m.id in ^memory_ids and is_nil(m.deleted_at),
            limit: ^limit,
            select: %{
              id: m.id,
              content: m.content,
              scope: m.scope,
              memory_type: m.memory_type,
              tags: m.tags,
              confidence: m.confidence
            }
          )
        )

      {:ok, %{results: rows}}
    end
  end

  def handle_facet_query(_), do: {:error, "facets array is required"}

  def handle_team_share(%{"memory_id" => memory_id, "team_id" => team_id})
      when is_binary(memory_id) and is_binary(team_id) do
    case Memory.team_share(memory_id, team_id) do
      :ok -> {:ok, %{memory_id: memory_id, namespace: "team:#{team_id}"}}
      {:error, :not_found} -> {:error, "memory not found"}
    end
  end

  def handle_team_share(_), do: {:error, "memory_id and team_id are required"}

  def handle_team_feed(%{"team_id" => team_id} = args) when is_binary(team_id) do
    limit = args["limit"] || 20
    rows = Memory.team_feed(team_id, limit)

    {:ok,
     %{
       team_id: team_id,
       results:
         Enum.map(rows, fn r ->
           %{
             id: r.id,
             content: r.content,
             namespace: r.namespace,
             memory_type: r.memory_type,
             tags: r.tags,
             inserted_at: r.inserted_at
           }
         end)
     }}
  end

  def handle_team_feed(_), do: {:error, "team_id is required"}

  def handle_lease(%{"action_id" => action_id, "agent_id" => agent_id} = args)
      when is_binary(action_id) and is_binary(agent_id) do
    ttl = args["ttl_seconds"] || 300

    case Lease.acquire(action_id, agent_id, ttl) do
      {:ok, lease_id} ->
        {:ok, %{lease_id: lease_id, action_id: action_id}}

      {:error, %{held_by: held_by, expires_at: expires_at}} ->
        {:error, "lease held by #{held_by} until #{DateTime.to_iso8601(expires_at)}"}

      {:error, :not_found} ->
        {:error, "failed to acquire lease"}
    end
  end

  def handle_lease(_), do: {:error, "action_id and agent_id are required"}

  def handle_signal_send(
        %{
          "sender_agent_id" => sender,
          "recipient_agent_id" => recipient,
          "topic" => topic
        } = args
      )
      when is_binary(sender) and is_binary(recipient) and is_binary(topic) do
    payload = args["payload"] || %{}

    case Signal.send_signal(sender, recipient, topic, payload) do
      {:ok, sig} -> {:ok, %{id: sig.id, sent_at: sig.sent_at}}
      {:error, changeset} -> {:error, format_changeset(changeset)}
    end
  end

  def handle_signal_send(_),
    do: {:error, "sender_agent_id, recipient_agent_id, and topic are required"}

  def handle_signal_read(%{"agent_id" => agent_id} = args) when is_binary(agent_id) do
    topic = args["topic"]
    limit = args["limit"] || 20

    case Signal.read_signals(agent_id, topic, limit) do
      {:ok, signals} ->
        {:ok,
         %{
           results:
             Enum.map(signals, fn s ->
               %{
                 id: s.id,
                 sender_agent_id: s.sender_agent_id,
                 topic: s.topic,
                 payload: s.payload,
                 sent_at: s.sent_at
               }
             end)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def handle_signal_read(_), do: {:error, "agent_id is required"}

  def handle_action_create(%{"title" => title} = args) when is_binary(title) do
    edges = args["edges"] || []

    attrs =
      %{"title" => title}
      |> maybe_put(args, "description")
      |> maybe_put(args, "priority")
      |> maybe_put(args, "project")
      |> maybe_put(args, "tags")
      |> maybe_put(args, "created_by")

    case Action.create(attrs, edges) do
      {:ok, action} ->
        {:ok,
         %{
           id: action.id,
           title: action.title,
           status: action.status,
           priority: action.priority
         }}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def handle_action_create(_), do: {:error, "title is required"}

  def handle_action_update(%{"action_id" => action_id, "status" => status})
      when is_binary(action_id) and is_binary(status) do
    case Action.update_status(action_id, status) do
      :ok -> {:ok, %{action_id: action_id, status: status}}
      {:error, :not_found} -> {:error, "action not found"}
      {:error, {:invalid_status, s}} -> {:error, "invalid status: #{s}"}
    end
  end

  def handle_action_update(_), do: {:error, "action_id and status are required"}

  def handle_frontier(args) when is_map(args) do
    project = args["project"]
    actions = Action.frontier(project)

    {:ok,
     %{
       results:
         Enum.map(actions, fn a ->
           %{
             id: a.id,
             title: a.title,
             status: a.status,
             priority: a.priority,
             project: a.project
           }
         end)
     }}
  end

  def handle_next(args) when is_map(args) do
    project = args["project"]

    case Action.next(project) do
      nil ->
        {:ok, %{action: nil}}

      a ->
        {:ok,
         %{
           action: %{
             id: a.id,
             title: a.title,
             status: a.status,
             priority: a.priority,
             project: a.project
           }
         }}
    end
  end

  # ──────────────────────────────────────────────
  # New core tool handlers
  # ──────────────────────────────────────────────

  def handle_smart_search(%{"query" => query} = args) when is_binary(query) do
    limit = args["limit"] || 5

    case Search.hybrid_recall(query, limit: limit) do
      {:ok, results} ->
        {:ok,
         %{
           results:
             Enum.map(results, fn r ->
               %{
                 id: r.id,
                 content: r.content,
                 scope: r.scope,
                 memory_type: r.memory_type,
                 tags: r.tags,
                 confidence: r.confidence,
                 inserted_at: r.inserted_at
               }
             end)
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def handle_smart_search(_), do: {:error, "query is required"}

  def handle_sessions(args) when is_map(args) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    limit = args["limit"] || 20

    q =
      from(s in BackplaneMemory.Observations.Session,
        order_by: [desc: s.started_at],
        limit: ^limit,
        select: %{
          session_id: s.session_id,
          project: s.project,
          observation_count: s.observation_count,
          started_at: s.started_at,
          ended_at: s.ended_at
        }
      )

    q =
      case args["project"] do
        p when is_binary(p) and p != "" -> where(q, [s], s.project == ^p)
        _ -> q
      end

    sessions = repo.all(q)
    {:ok, %{sessions: sessions}}
  end

  def handle_patterns(args) when is_map(args) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    limit = args["limit"] || 10

    q =
      from(o in BackplaneMemory.Observations.Observation,
        where: not is_nil(o.tool_name),
        group_by: o.tool_name,
        order_by: [desc: count(o.id)],
        limit: ^limit,
        select: %{tool_name: o.tool_name, count: count(o.id)}
      )

    q =
      case args["session_id"] do
        s when is_binary(s) and s != "" -> where(q, [o], o.session_id == ^s)
        _ -> q
      end

    top_tools = repo.all(q)
    {:ok, %{top_tools: top_tools}}
  end

  def handle_timeline(args) when is_map(args) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    limit = args["limit"] || 50

    q =
      from(o in BackplaneMemory.Observations.Observation,
        order_by: [asc: o.created_at],
        limit: ^limit,
        select: %{
          id: o.id,
          session_id: o.session_id,
          tool_name: o.tool_name,
          content: o.content,
          is_error: o.is_error,
          created_at: o.created_at
        }
      )

    q =
      case args["session_id"] do
        s when is_binary(s) and s != "" -> where(q, [o], o.session_id == ^s)
        _ -> q
      end

    observations = repo.all(q)

    grouped =
      observations
      |> Enum.group_by(& &1.session_id)
      |> Enum.map(fn {session_id, obs} -> %{session_id: session_id, observations: obs} end)

    {:ok, %{timeline: grouped}}
  end

  def handle_export(args) when is_map(args) do
    scope = args["scope"] || "global"
    rows = Memory.list(scope: scope, limit: 10_000)

    {:ok,
     %{
       scope: scope,
       count: length(rows),
       memories:
         Enum.map(rows, fn r ->
           %{
             id: r.id,
             content: r.content,
             memory_type: r.memory_type,
             scope: r.scope,
             tags: r.tags,
             metadata: r.metadata,
             inserted_at: r.inserted_at
           }
         end)
     }}
  end

  def handle_relations(%{"entity" => entity} = args) when is_binary(entity) do
    depth = args["depth"] || 1

    case BackplaneMemory.Graph.BFS.query(entity, depth) do
      {:ok, %{nodes: nodes, edges: edges}} ->
        {:ok,
         %{
           nodes: Enum.map(nodes, &Map.take(&1, [:id, :name, :type])),
           edges:
             Enum.map(edges, fn e ->
               Map.take(e, [:id, :source_id, :target_id, :relation])
             end)
         }}

      error ->
        {:error, inspect(error)}
    end
  end

  def handle_relations(_), do: {:error, "entity is required"}

  def handle_compress_file(%{"file_path" => path, "agent_id" => agent_id, "host_id" => host_id})
      when is_binary(path) and is_binary(agent_id) and is_binary(host_id) do
    rows = BackplaneMemory.Observations.file_history([path], limit: 200)

    if rows == [] do
      {:ok, %{status: "no_observations", file_path: path}}
    else
      summary =
        rows
        |> Enum.map(& &1.content)
        |> Enum.join("\n")
        |> String.slice(0, 4000)

      content = "File summary for #{path}:\n#{summary}"

      case Memory.remember(content,
             type: "semantic",
             scope: path,
             agent_id: agent_id,
             host_id: host_id,
             tags: ["file_summary", path]
           ) do
        {:ok, mem} ->
          {:ok, %{status: "compressed", memory_id: mem.id, file_path: path}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  def handle_compress_file(_),
    do: {:error, "file_path, agent_id, and host_id are required"}

  def handle_audit(args) when is_map(args) do
    opts =
      [
        limit: args["limit"] || 50,
        offset: args["offset"] || 0
      ]
      |> then(fn o ->
        case args["operation"] do
          op when is_binary(op) and op != "" -> Keyword.put(o, :operation, op)
          _ -> o
        end
      end)
      |> then(fn o ->
        case args["actor"] do
          a when is_binary(a) and a != "" -> Keyword.put(o, :actor, a)
          _ -> o
        end
      end)

    entries = BackplaneMemory.Audit.list(opts)
    {:ok, %{entries: entries}}
  end

  def handle_governance_delete(%{"memory_id" => memory_id} = args)
      when is_binary(memory_id) do
    actor = args["actor"] || "system"
    reason = args["reason"] || "governance_delete"
    hard_delete = Backplane.Settings.get("memory.hard_delete_enabled") == "true"

    with {:ok, _mem} <- Memory.get(memory_id) do
      BackplaneMemory.Audit.log(
        "governance_delete",
        actor,
        %{"memory_id" => memory_id},
        %{"reason" => reason, "hard_delete" => hard_delete}
      )

      if hard_delete do
        repo = Application.fetch_env!(:backplane_memory, :repo)

        repo.delete_all(from(m in BackplaneMemory.Memories.Memory, where: m.id == ^memory_id))

        {:ok, %{memory_id: memory_id, status: "hard_deleted", actor: actor}}
      else
        case Memory.forget(memory_id) do
          :ok -> {:ok, %{memory_id: memory_id, status: "soft_deleted", actor: actor}}
          {:error, :not_found} -> {:error, "memory not found"}
        end
      end
    else
      {:error, :not_found} -> {:error, "memory not found"}
    end
  end

  def handle_governance_delete(_), do: {:error, "memory_id is required"}

  def handle_diagnose(_args) do
    stats = Memory.stats()

    repo = Application.fetch_env!(:backplane_memory, :repo)
    lease_count = repo.aggregate(BackplaneMemory.Coordination.Lease, :count, :id)

    {:ok,
     %{
       status: "ok",
       memory_stats: stats,
       active_leases: lease_count
     }}
  end

  def handle_heal(_args) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    now = DateTime.utc_now()

    {deleted, _} =
      repo.delete_all(from(l in BackplaneMemory.Coordination.Lease, where: l.expires_at < ^now))

    {:ok, %{status: "healed", expired_leases_cleared: deleted}}
  end

  # ──────────────────────────────────────────────
  # Extended tool handlers
  # ──────────────────────────────────────────────

  def handle_graph_query(%{"entity" => entity} = args) when is_binary(entity) do
    depth = args["depth"] || 2
    relation = args["relation"]

    case BackplaneMemory.Graph.BFS.query(entity, depth, relation) do
      {:ok, %{nodes: nodes, edges: edges}} ->
        {:ok,
         %{
           nodes: Enum.map(nodes, &Map.take(&1, [:id, :name, :type])),
           edges:
             Enum.map(edges, fn e ->
               Map.take(e, [:id, :source_id, :target_id, :relation])
             end)
         }}

      error ->
        {:error, inspect(error)}
    end
  end

  def handle_graph_query(_), do: {:error, "entity is required"}

  def handle_graph_stats(_args) do
    {:ok, BackplaneMemory.Graph.stats()}
  end

  def handle_consolidate(%{"session_id" => session_id}) when is_binary(session_id) do
    # Enqueue a profile build as the consolidation mechanism
    BackplaneMemory.Workers.ProfileBuildWorker.enqueue(session_id)
    {:ok, %{status: "queued", session_id: session_id}}
  end

  def handle_consolidate(_), do: {:error, "session_id is required"}

  def handle_verify(%{"memory_id" => memory_id}) when is_binary(memory_id) do
    case Memory.get(memory_id) do
      {:ok, mem} ->
        {:ok,
         %{
           exists: true,
           memory_id: memory_id,
           memory_type: mem.memory_type,
           scope: mem.scope
         }}

      {:error, :not_found} ->
        {:ok, %{exists: false, memory_id: memory_id}}
    end
  end

  def handle_verify(_), do: {:error, "memory_id is required"}

  def handle_slot_read(%{"name" => name}) when is_binary(name) do
    case BackplaneMemory.Slots.read(name) do
      {:ok, slot} ->
        {:ok,
         %{
           name: slot.name,
           content: slot.content,
           updated_at: slot.updated_at,
           updated_by: slot.updated_by,
           size_limit_chars: slot.size_limit_chars
         }}

      {:error, :not_found} ->
        {:error, "slot not found: #{name}"}
    end
  end

  def handle_slot_read(_), do: {:error, "name is required"}

  def handle_slot_write(%{"name" => name, "content" => content} = args)
      when is_binary(name) and is_binary(content) do
    updated_by = args["updated_by"]

    case BackplaneMemory.Slots.write(name, content, updated_by) do
      {:ok, slot} ->
        {:ok, %{name: slot.name, updated_at: slot.updated_at}}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def handle_slot_write(_), do: {:error, "name and content are required"}

  def handle_slot_list(_args) do
    slots = BackplaneMemory.Slots.list()

    {:ok,
     %{
       slots:
         Enum.map(slots, fn s ->
           %{
             name: s.name,
             content: s.content,
             updated_at: s.updated_at,
             updated_by: s.updated_by,
             size_limit_chars: s.size_limit_chars
           }
         end)
     }}
  end

  def handle_enrich(%{"memory_id" => memory_id} = args) when is_binary(memory_id) do
    repo = Application.fetch_env!(:backplane_memory, :repo)

    case repo.get(BackplaneMemory.Memories.Memory, memory_id) do
      nil ->
        {:error, "memory not found"}

      mem ->
        new_tags = (mem.tags ++ (args["tags"] || [])) |> Enum.uniq()

        new_metadata =
          Map.merge(mem.metadata || %{}, args["metadata"] || %{})

        {1, _} =
          repo.update_all(
            from(m in BackplaneMemory.Memories.Memory, where: m.id == ^memory_id),
            set: [tags: new_tags, metadata: new_metadata]
          )

        {:ok, %{memory_id: memory_id, tags: new_tags}}
    end
  end

  def handle_enrich(_), do: {:error, "memory_id is required"}

  def handle_access_log(%{"memory_id" => memory_id}) when is_binary(memory_id) do
    repo = Application.fetch_env!(:backplane_memory, :repo)

    result =
      repo.one(
        from(m in BackplaneMemory.Memories.Memory,
          where: m.id == ^memory_id,
          select: %{
            id: m.id,
            access_count: m.access_count,
            accessed_at: m.accessed_at,
            inserted_at: m.inserted_at
          }
        )
      )

    case result do
      nil -> {:error, "memory not found"}
      row -> {:ok, row}
    end
  end

  def handle_access_log(_), do: {:error, "memory_id is required"}

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp maybe_put(map, args, key) do
    case args[key] do
      nil -> map
      val -> Map.put(map, key, val)
    end
  end

  defp add_if(opts, args, key, opt_key) do
    case args[key] do
      v when is_binary(v) and v != "" -> Keyword.put(opts, opt_key, v)
      _ -> opts
    end
  end

  defp format_changeset(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join(", ")
  end
end
