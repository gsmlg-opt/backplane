defmodule Backplane.Memory.Service do
  @moduledoc "Managed MCP service exposing memory::* tools."

  @behaviour Backplane.Services.ManagedService

  import Ecto.Query

  alias Backplane.Memory.Coordination.{Action, Lease, Signal}
  alias Backplane.Memory.Authorization
  alias Backplane.Memory.Activity
  alias Backplane.Memory.Audit
  alias Backplane.Memory.Config
  alias Backplane.Memory.Context
  alias Backplane.Memory.Crystals
  alias Backplane.Memory.Lessons
  alias Backplane.Memory.Memories
  alias Backplane.Memory.Memories.Search
  alias Backplane.Memory.Profiles
  alias Backplane.Memory.Projections.ReadModels
  alias Backplane.Memory.Recall.Pipeline
  alias Backplane.Memory.Recall.Store, as: RecallStore
  alias Backplane.Memory.Replay
  alias Backplane.Registry.InputValidator
  alias Backplane.Skills.AgentManage

  @file_compression_processing_version "file-compression-v1"
  @lifecycle_context_ttl_seconds 15 * 60
  @lesson_tool_names ~w(
    memory::lesson_save
    memory::lesson_recall
    memory::lesson_strengthen
    memory::lesson_promote
    memory::lesson_archive
  )
  @activity_tool_names ~w(
    memory::activity_summary
    memory::replay_sessions
    memory::replay_load
    memory::replay_import
  )
  @replay_tool_names @activity_tool_names -- ~w(memory::activity_summary)
  @replay_import_tools ~w(memory::replay_import)

  @impl true
  def prefix, do: "memory"

  @impl true
  def enabled?, do: Backplane.Settings.get("services.memory.enabled") == true

  @impl true
  def tools do
    (core_tools() ++ extended_tools())
    |> Enum.reject(&disabled_replay_tool?/1)
    |> Enum.map(&secure_tool/1)
  end

  @doc "Dispatches a Memory tool through the same authorization boundary used by MCP."
  def call(_name, %{"__trusted_internal__" => _value}, _auth), do: {:error, :invalid_arguments}

  def call(name, args, auth) when is_binary(name) and is_map(args) and is_map(auth) do
    case Enum.find(tools(), &(&1.name == name)) do
      %{handler: handler, input_schema: schema} ->
        case InputValidator.validate(args, schema) do
          :ok -> handler.(args, auth)
          {:error, _reason} -> {:error, :invalid_arguments}
        end

      nil ->
        {:error, {:unknown_tool, name}}
    end
  end

  if Mix.env() == :test do
    @doc false
    def trusted_call(name, args) when is_binary(name) and is_map(args) do
      case Enum.find(core_tools() ++ extended_tools(true), &(&1.name == name)) do
        %{handler: handler} -> handler.(Map.put(args, "__trusted_internal__", true))
        nil -> {:error, {:unknown_tool, name}}
      end
    end
  end

  @doc "Authenticated direct boundary for listing memories."
  def handle_list(args, auth), do: call("memory::list", args, auth)
  def handle_list(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for forgetting a memory."
  def handle_forget(args, auth), do: call("memory::forget", args, auth)
  def handle_forget(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for verifying a memory."
  def handle_verify(args, auth), do: call("memory::verify", args, auth)
  def handle_verify(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for enriching a memory."
  def handle_enrich(args, auth), do: call("memory::enrich", args, auth)
  def handle_enrich(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for reading a memory access log."
  def handle_access_log(args, auth), do: call("memory::access_log", args, auth)
  def handle_access_log(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for recording a successful memory application."
  def handle_apply(args, auth), do: call("memory::apply", args, auth)
  def handle_apply(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for tagging memory facets."
  def handle_facet_tag(args, auth), do: call("memory::facet_tag", args, auth)
  def handle_facet_tag(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for querying memory facets."
  def handle_facet_query(args, auth), do: call("memory::facet_query", args, auth)
  def handle_facet_query(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for sharing a memory with a team."
  def handle_team_share(args, auth), do: call("memory::team_share", args, auth)
  def handle_team_share(_args), do: {:error, :unauthorized}

  @doc "Authenticated direct boundary for reading a team feed."
  def handle_team_feed(args, auth), do: call("memory::team_feed", args, auth)
  def handle_team_feed(_args), do: {:error, :unauthorized}

  for {handler, tool} <- [
        handle_recall: "memory::recall",
        handle_lesson_save: "memory::lesson_save",
        handle_lesson_recall: "memory::lesson_recall",
        handle_lesson_strengthen: "memory::lesson_strengthen",
        handle_lesson_promote: "memory::lesson_promote",
        handle_lesson_archive: "memory::lesson_archive",
        handle_crystallize: "memory::crystallize",
        handle_crystal_get: "memory::crystal_get",
        handle_crystal_list: "memory::crystal_list",
        handle_crystal_search: "memory::crystal_search",
        handle_stats: "memory::stats",
        handle_profile: "memory::profile",
        handle_profile_refresh: "memory::profile_refresh",
        handle_expand_query: "memory::expand_query",
        handle_file_history: "memory::file_history",
        handle_lease: "memory::lease",
        handle_signal_send: "memory::signal_send",
        handle_signal_read: "memory::signal_read",
        handle_action_create: "memory::action_create",
        handle_action_update: "memory::action_update",
        handle_frontier: "memory::frontier",
        handle_next: "memory::next",
        handle_smart_search: "memory::smart_search",
        handle_sessions: "memory::sessions",
        handle_patterns: "memory::patterns",
        handle_timeline: "memory::timeline",
        handle_export: "memory::export",
        handle_activity_summary: "memory::activity_summary",
        handle_replay_sessions: "memory::replay_sessions",
        handle_replay_load: "memory::replay_load",
        handle_replay_import: "memory::replay_import",
        handle_relations: "memory::relations",
        handle_compress_file: "memory::compress_file",
        handle_audit: "memory::audit",
        handle_governance_delete: "memory::governance_delete",
        handle_diagnose: "memory::diagnose",
        handle_heal: "memory::heal",
        handle_graph_query: "memory::graph_query",
        handle_graph_stats: "memory::graph_stats",
        handle_consolidate: "memory::consolidate",
        handle_slot_read: "memory::slot_read",
        handle_slot_write: "memory::slot_write",
        handle_slot_list: "memory::slot_list"
      ] do
    def unquote(handler)(args, auth), do: call(unquote(tool), args, auth)
    def unquote(handler)(_args), do: {:error, :unauthorized}
  end

  defp secure_tool(%{name: name, handler: handler} = tool) do
    permission = Backplane.MemoryPermissions.for_tool!(name)

    Map.merge(tool, %{
      permission: permission,
      handler: fn args, auth -> authorized_tool_call(name, handler, args, auth) end
    })
  end

  defp authorized_tool_call(name, handler, args, auth) do
    with {:ok, trusted_args, _partition} <- Authorization.authorize_tool(name, args, auth) do
      Backplane.Memory.PipelineTelemetry.span("tool." <> name, trusted_args, fn ->
        case :erlang.fun_info(handler, :arity) do
          {:arity, 2} -> handler.(args, auth)
          {:arity, 1} -> handler.(trusted_args)
        end
      end)
    end
  end

  defp all_core_tools do
    [
      %{
        name: "memory::activity_summary",
        description: "Summarize durable activity in the exact authenticated partition.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "date_from" => %{"type" => "string", "format" => "date"},
            "date_to" => %{"type" => "string", "format" => "date"},
            "project" => %{"type" => "string", "maxLength" => 512},
            "agent_id" => %{"type" => "string", "maxLength" => 512},
            "event_type" => %{"type" => "string", "maxLength" => 512}
          },
          "additionalProperties" => false
        },
        handler: &do_handle_activity_summary/1
      },
      %{
        name: "memory::recall_explain",
        description:
          "Explain one bounded Recall Inspector trace from the exact authenticated partition.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "recall_run_id" => %{"type" => "string", "format" => "uuid"}
          },
          "required" => ["recall_run_id"],
          "additionalProperties" => false
        },
        handler: &do_handle_recall_explain/1
      },
      %{
        name: "memory::replay_sessions",
        description: "List replayable sessions in the exact authenticated partition.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20},
            "offset" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => 10_000,
              "default" => 0
            }
          },
          "additionalProperties" => false
        },
        handler: &do_handle_replay_sessions/1
      },
      %{
        name: "memory::replay_load",
        description: "Load a bounded page of privacy-safe replay events for one session.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "session_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 512},
            "cursor" => %{"type" => "string", "maxLength" => 4096},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 50}
          },
          "required" => ["session_id"],
          "additionalProperties" => false
        },
        handler: &do_handle_replay_load/1
      },
      %{
        name: "memory::replay_import",
        description:
          "Request a configured host-local replay import without transmitting filesystem paths.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "request_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
            "profile" => %{
              "type" => "string",
              "pattern" => "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"
            },
            "integration" => %{
              "type" => "string",
              "enum" => ["claude_code"],
              "default" => "claude_code"
            }
          },
          "required" => ["profile"],
          "additionalProperties" => false
        },
        handler: &do_handle_replay_import/1
      },
      %{
        name: "memory::crystallize",
        description: "Crystallize a closed session or completed connected action chain.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "source_kind" => %{"type" => "string", "enum" => ["session", "action_chain"]},
            "session_id" => %{"type" => "string"},
            "root_action_id" => %{"type" => "string"},
            "allow_nonterminal" => %{"type" => "boolean", "default" => false},
            "request_id" => %{"type" => "string"},
            "correlation_id" => %{"type" => "string"}
          },
          "required" => ["source_kind"],
          "additionalProperties" => false
        },
        handler: &do_handle_crystallize/2
      },
      %{
        name: "memory::crystal_get",
        description: "Read one crystal and its typed provenance links.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"crystal_id" => %{"type" => "string"}},
          "required" => ["crystal_id"],
          "additionalProperties" => false
        },
        handler: &do_handle_crystal_get/1
      },
      %{
        name: "memory::crystal_list",
        description: "List recent crystals from the exact authenticated partition.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20},
            "after" => %{"type" => "string", "maxLength" => 4096}
          },
          "additionalProperties" => false
        },
        handler: &do_handle_crystal_list/1
      },
      %{
        name: "memory::crystal_search",
        description: "Search completed crystals in the exact authenticated partition.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "maxLength" => 4096},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20}
          },
          "required" => ["query"],
          "additionalProperties" => false
        },
        handler: &do_handle_crystal_search/1
      },
      %{
        name: "memory::lesson_save",
        description: "Save an active procedural lesson with durable evidence.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "rule" => %{"type" => "string"},
            "context" => %{"type" => "string"},
            "project" => %{"type" => "string"},
            "session_id" => %{"type" => "string"},
            "idempotency_key" => %{"type" => "string"},
            "request_id" => %{"type" => "string"},
            "correlation_id" => %{"type" => "string"}
          },
          "required" => ["rule", "context", "project", "idempotency_key"],
          "additionalProperties" => false
        },
        handler: &do_handle_lesson_save/2
      },
      %{
        name: "memory::lesson_recall",
        description: "Recall active lessons from the authenticated memory partition.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "project" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 10}
          },
          "required" => ["query"],
          "additionalProperties" => false
        },
        handler: &do_handle_lesson_recall/1
      },
      %{
        name: "memory::lesson_strengthen",
        description:
          "Strengthen a lesson from explicit confirmation, verified application, or independent evidence.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "mode" => %{
              "type" => "string",
              "enum" => ["explicit_confirmation", "verified_application", "independent_evidence"]
            },
            "idempotency_key" => %{"type" => "string"},
            "source_event_id" => %{"type" => "string"},
            "source_observation_id" => %{"type" => "string"},
            "source_summary_id" => %{"type" => "string"},
            "source_request_id" => %{"type" => "string"},
            "source_session_id" => %{"type" => "string"},
            "request_id" => %{"type" => "string"},
            "correlation_id" => %{"type" => "string"}
          },
          "required" => ["memory_id", "mode", "idempotency_key"],
          "additionalProperties" => false
        },
        handler: &do_handle_lesson_strengthen/2
      },
      %{
        name: "memory::lesson_promote",
        description: "Promote an evidence-backed lesson candidate.",
        input_schema: lesson_transition_schema(nil),
        handler: &do_handle_lesson_promote/2
      },
      %{
        name: "memory::lesson_archive",
        description: "Archive, reactivate, or dispute a lesson.",
        input_schema: lesson_transition_schema(["archive", "reactivate", "dispute"]),
        handler: &do_handle_lesson_archive/2
      },
      %{
        name: "memory::apply",
        description: "Record one successful application of a procedural memory.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "application_id" => %{"type" => "string"},
            "applied_by" => %{"type" => "string"}
          },
          "required" => ["memory_id", "application_id", "applied_by"],
          "additionalProperties" => false
        },
        handler: &do_handle_apply/1
      },
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
        handler: &do_handle_facet_tag/1
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
        handler: &do_handle_facet_query/1
      },
      %{
        name: "memory::remember",
        description: "Persist a memory entry with durable request idempotency.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "content" => %{"type" => "string", "description" => "Memory text"},
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
            },
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
            "idempotency_key" => %{"type" => "string"},
            "session_id" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "metadata" => %{"type" => "object"}
          },
          "required" => ["content", "agent_id"],
          "additionalProperties" => false
        },
        handler: &handle_remember/2
      },
      %{
        name: "memory::recall",
        description:
          "Search memories by query. Uses vector search when configured, with full-text fallback.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Query text"},
            "limit" => %{"type" => "integer", "default" => 10},
            "scope" => %{"type" => "string"},
            "agent_id" => %{"type" => "string"},
            "host_id" => %{"type" => "string"},
            "tag" => %{"type" => "string"},
            "project" => %{"type" => "string"},
            "token_budget" => %{"type" => "integer"},
            "temporal_hints" => %{"type" => "object"},
            "entity_hints" => %{"type" => "array", "items" => %{"type" => "string"}},
            "include_working" => %{"type" => "boolean", "default" => false},
            "channel_weights" => %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "fts" => %{"type" => "number"},
                "vector" => %{"type" => "number"},
                "graph" => %{"type" => "number"}
              }
            },
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
          "required" => ["query"],
          "additionalProperties" => false
        },
        handler: &do_handle_recall/1
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
        handler: &do_handle_list/1
      },
      %{
        name: "memory::forget",
        description: "Soft-delete a memory by id.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"]
        },
        handler: &do_handle_forget/1
      },
      %{
        name: "memory::stats",
        description: "Return counts grouped by memory_type.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: &do_handle_stats/1
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
        handler: &do_handle_profile/1
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
        handler: &do_handle_profile_refresh/1
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
        handler: &do_handle_expand_query/1
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
        handler: &do_handle_file_history/1
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
        handler: &do_handle_team_share/1
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
        handler: &do_handle_team_feed/1
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
        handler: &do_handle_lease/1
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
        handler: &do_handle_signal_send/1
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
        handler: &do_handle_signal_read/1
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
            "source_observation_ids" => uuid_array_schema(),
            "source_memory_ids" => uuid_array_schema(),
            "source_session_ids" => %{
              "type" => "array",
              "items" => %{"type" => "string"}
            },
            "source_lesson_ids" => uuid_array_schema(),
            "source_crystal_ids" => uuid_array_schema(),
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
        handler: &do_handle_action_create/1
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
        handler: &do_handle_action_update/1
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
        handler: &do_handle_frontier/1
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
        handler: &do_handle_next/1
      },
      %{
        name: "memory::smart_search",
        description: "Vector-preferred memory search with full-text fallback.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "default" => 5}
          },
          "required" => ["query"]
        },
        handler: &do_handle_smart_search/1
      },
      %{
        name: "memory::sessions",
        description: "List memory sessions with id, project, observation count, and times.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 100,
              "default" => 20,
              "description" => "Maximum projected sessions to return"
            },
            "offset" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => 10_000,
              "default" => 0,
              "description" => "Projected session rows to skip"
            },
            "project" => %{"type" => "string", "description" => "Exact canonical project"},
            "host_id" => %{"type" => "string", "description" => "Exact canonical host ID"},
            "session_id" => %{
              "type" => "string",
              "description" => "Exact canonical session ID"
            }
          }
        },
        handler: &do_handle_sessions/1
      },
      %{
        name: "memory::patterns",
        description: "Group observations by tool_name and return top tools and file patterns.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project" => %{"type" => "string", "description" => "Exact canonical project"},
            "session_id" => %{
              "type" => "string",
              "description" => "Exact canonical session ID"
            },
            "host_id" => %{"type" => "string", "description" => "Exact canonical host ID"},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 100,
              "default" => 10,
              "description" => "Maximum tool patterns to return"
            },
            "offset" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => 10_000,
              "default" => 0,
              "description" => "Aggregated tool patterns to skip"
            }
          }
        },
        handler: &do_handle_patterns/1
      },
      %{
        name: "memory::timeline",
        description: "Observations ordered by time, grouped by session.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project" => %{"type" => "string", "description" => "Exact canonical project"},
            "session_id" => %{
              "type" => "string",
              "description" => "Exact canonical session ID"
            },
            "host_id" => %{"type" => "string", "description" => "Exact canonical host ID"},
            "event_type" => %{
              "type" => "string",
              "description" => "Exact canonical event type"
            },
            "tool_name" => %{
              "type" => "string",
              "description" => "Exact projected tool name"
            },
            "minimum_importance" => %{
              "type" => "integer",
              "minimum" => -2_147_483_648,
              "maximum" => 2_147_483_647,
              "description" => "Minimum canonical event importance, inclusive"
            },
            "is_error" => %{
              "type" => "boolean",
              "description" => "Filter projected events by error status"
            },
            "file_path" => %{
              "type" => "string",
              "description" => "Exact projected file path membership"
            },
            "occurred_from" => %{
              "type" => "string",
              "format" => "date-time",
              "description" => "Earliest canonical occurrence time, inclusive"
            },
            "occurred_to" => %{
              "type" => "string",
              "format" => "date-time",
              "description" => "Latest canonical occurrence time, inclusive"
            },
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 100,
              "default" => 50,
              "description" => "Maximum projected timeline events to return"
            },
            "offset" => %{
              "type" => "integer",
              "minimum" => 0,
              "maximum" => 10_000,
              "default" => 0,
              "description" => "Filtered projected timeline events to skip"
            }
          }
        },
        handler: &do_handle_timeline/1
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
        handler: &do_handle_export/1
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
        handler: &do_handle_relations/1
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
        handler: &do_handle_compress_file/1
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
        handler: &do_handle_audit/1
      },
      %{
        name: "memory::governance_delete",
        description:
          "Soft-delete a memory with audit trail. Hard-delete only if memory.hard_delete_enabled=true.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "memory_id" => %{"type" => "string"},
            "reason" => %{"type" => "string"}
          },
          "required" => ["memory_id"]
        },
        handler: &do_handle_governance_delete/1
      },
      %{
        name: "memory::diagnose",
        description: "System health: circuit breaker state, queue depth, and memory stats.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: &do_handle_diagnose/1
      },
      %{
        name: "memory::heal",
        description:
          "Run an idempotent partition-scoped repair, or clear expired leases when kind is omitted.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "kind" => %{
              "type" => "string",
              "enum" => Backplane.Memory.Operations.Repair.kinds()
            },
            "idempotency_key" => %{"type" => "string", "minLength" => 1},
            "target_id" => %{"type" => "string", "minLength" => 1},
            "session_id" => %{"type" => "string", "minLength" => 1},
            "project" => %{"type" => "string", "minLength" => 1},
            "date_from" => %{"type" => "string", "format" => "date"},
            "date_to" => %{"type" => "string", "format" => "date"},
            "resolution" => %{"type" => "string", "enum" => ~w(confirmed rejected)},
            "action" => %{
              "type" => "string",
              "enum" => ~w(promote activate archive dispute supersede)
            },
            "reason" => %{"type" => "string", "minLength" => 1}
          },
          "additionalProperties" => false
        },
        handler: &do_handle_heal/1
      }
    ]
  end

  defp lesson_transition_schema(actions) do
    properties = %{
      "memory_id" => %{"type" => "string"},
      "reason" => %{"type" => "string"},
      "idempotency_key" => %{"type" => "string"},
      "request_id" => %{"type" => "string"},
      "correlation_id" => %{"type" => "string"}
    }

    {properties, required} =
      if actions do
        {Map.put(properties, "action", %{"type" => "string", "enum" => actions}),
         ["memory_id", "action", "reason", "idempotency_key"]}
      else
        {properties, ["memory_id", "reason", "idempotency_key"]}
      end

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  @lesson_governance_tools @lesson_tool_names -- ~w(memory::lesson_save memory::lesson_recall)
  @crystal_governance_tools ~w(memory::crystallize)

  defp core_tools,
    do:
      Enum.reject(
        all_core_tools(),
        &(&1.name in @lesson_governance_tools or &1.name in @crystal_governance_tools or
            &1.name in @replay_import_tools)
      )

  defp lesson_governance_tools,
    do: Enum.filter(all_core_tools(), &(&1.name in @lesson_governance_tools))

  defp extended_tools, do: extended_tools(Backplane.Settings.get("memory.tools") == "all")

  defp extended_tools(enabled?) do
    if enabled? do
      lesson_governance_tools() ++
        crystal_governance_tools() ++
        replay_import_tools() ++
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
            handler: &do_handle_graph_query/1
          },
          %{
            name: "memory::graph_stats",
            description: "Return knowledge graph node and edge counts grouped by type/relation.",
            input_schema: %{"type" => "object", "properties" => %{}},
            handler: &do_handle_graph_stats/1
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
            handler: &do_handle_consolidate/1
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
            handler: &do_handle_verify/1
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
            handler: &do_handle_slot_read/1
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
            handler: &do_handle_slot_write/1
          },
          %{
            name: "memory::slot_list",
            description: "List all memory slots and their content.",
            input_schema: %{"type" => "object", "properties" => %{}},
            handler: &do_handle_slot_list/1
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
            handler: &do_handle_enrich/1
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
            handler: &do_handle_access_log/1
          }
        ]
    else
      []
    end
  end

  defp crystal_governance_tools,
    do: Enum.filter(all_core_tools(), &(&1.name in @crystal_governance_tools))

  defp replay_import_tools,
    do: Enum.filter(all_core_tools(), &(&1.name in @replay_import_tools))

  defp disabled_replay_tool?(%{name: "memory::replay_import"}),
    do: not Config.replay_import_enabled?()

  defp disabled_replay_tool?(%{name: name}) when name in @replay_tool_names,
    do: not Config.replay_enabled?()

  defp disabled_replay_tool?(_tool), do: false

  # ──────────────────────────────────────────────
  # Resources
  # ──────────────────────────────────────────────

  @doc "Legacy resource enumeration is fail-closed; pass authenticated context to resources/1."
  def resources, do: []

  def resources(auth) when is_map(auth) do
    available = MapSet.new(tools(), & &1.name)

    resource_descriptors()
    |> Enum.filter(fn descriptor ->
      MapSet.member?(available, descriptor.tool) and
        match?(
          {:ok, _args, _partition},
          Authorization.authorize_tool(descriptor.tool, %{}, auth)
        )
    end)
    |> Enum.map(&Map.delete(&1, :tool))
  end

  @doc "Legacy resource template enumeration is fail-closed; pass authenticated context."
  def resource_templates, do: []

  def resource_templates(auth) when is_map(auth) do
    resource_template_descriptors()
    |> Enum.filter(fn descriptor ->
      match?(
        {:ok, _args, _partition},
        Authorization.authorize_tool(descriptor.tool, %{}, auth)
      )
    end)
    |> Enum.map(&Map.delete(&1, :tool))
  end

  defp resource_template_descriptors do
    [
      %{
        uri_template: "memory://session/{id}/handoff",
        name: "Memory Session Handoff",
        description: "Bounded source-linked handoff for one authorized session",
        mime_type: "application/json",
        tool: "memory::sessions"
      },
      %{
        uri_template: "memory://recall/{id}/trace",
        name: "Memory Recall Trace",
        description: "Bounded Recall Inspector trace from the authorized partition",
        mime_type: "application/json",
        tool: "memory::recall_explain"
      }
    ]
  end

  defp resource_descriptors do
    [
      %{
        uri: "memory://activity/summary",
        name: "Memory Activity Summary",
        description: "Durable activity counters for the authorized memory partition",
        mime_type: "application/json",
        tool: "memory::activity_summary"
      },
      %{
        uri: "memory://status",
        name: "Memory Status",
        description: "Health, session count, memory count",
        mime_type: "application/json",
        tool: "memory::stats"
      },
      %{
        uri: "memory://memories/latest",
        name: "Latest Memories",
        description: "Latest 10 active memories",
        mime_type: "application/json",
        tool: "memory::list"
      },
      %{
        uri: "memory://lessons/top",
        name: "Top Lessons",
        description: "Highest-priority active lessons in the authorized memory partition",
        mime_type: "application/json",
        tool: "memory::lesson_recall"
      },
      %{
        uri: "memory://crystals/latest",
        name: "Latest Crystals",
        description: "Latest completed-work crystals in the authorized memory partition",
        mime_type: "application/json",
        tool: "memory::crystal_list"
      },
      %{
        uri: "memory://graph/stats",
        name: "Graph Stats",
        description: "Knowledge graph node and edge counts",
        mime_type: "application/json",
        tool: "memory::graph_stats"
      },
      %{
        uri: "memory://sessions/active",
        name: "Active Sessions",
        description: "Currently active sessions",
        mime_type: "application/json",
        tool: "memory::sessions"
      },
      %{
        uri: "memory://audit/recent",
        name: "Recent Audit",
        description: "Last 50 audit log entries",
        mime_type: "application/json",
        tool: "memory::audit"
      }
    ]
  end

  @doc "Legacy resource reads are fail-closed; pass authenticated context to read_resource/2."
  def read_resource(_uri), do: {:error, :unauthorized}

  def read_resource("memory://session/" <> rest = uri, auth) when is_map(auth) do
    with [encoded_id, "handoff"] <- String.split(rest, "/", parts: 2),
         {:ok, session_id} <- decode_resource_id(encoded_id),
         {:ok, _trusted_args, partition} <-
           Authorization.authorize_tool("memory::sessions", %{}, auth),
         {:ok, project} <- resource_session_project(session_id, partition),
         {:ok, prompt} <-
           Backplane.Memory.Prompts.get(
             "session_handoff",
             %{"session_id" => session_id, "project" => project},
             auth
           ) do
      {:ok, Jason.encode!(%{uri: uri, handoff: prompt})}
    else
      _ -> {:error, :not_found}
    end
  end

  def read_resource("memory://recall/" <> rest, auth) when is_map(auth) do
    with [encoded_id, "trace"] <- String.split(rest, "/", parts: 2),
         {:ok, recall_run_id} <- decode_resource_id(encoded_id),
         {:ok, result} <-
           call("memory::recall_explain", %{"recall_run_id" => recall_run_id}, auth) do
      {:ok, Jason.encode!(result)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_found}
    end
  end

  def read_resource("memory://lessons/top", auth) when is_map(auth) do
    with {:ok, _trusted_args, partition} <-
           Authorization.authorize_tool("memory::lesson_recall", %{}, auth),
         {:ok, lessons} <-
           Lessons.top(Map.put(partition, :client_id, partition.partition_id), limit: 10) do
      results = Enum.map(lessons, &lesson_resource/1)
      {:ok, Jason.encode!(%{results: results})}
    end
  end

  def read_resource(uri, auth) when is_binary(uri) and is_map(auth) do
    with %{tool: tool} <- Enum.find(resource_descriptors(), &(&1.uri == uri)),
         {:ok, result} <- call(tool, resource_arguments(uri), auth) do
      {:ok, Jason.encode!(resource_result(uri, result))}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_resource_id(encoded_id) when is_binary(encoded_id) and encoded_id != "" do
    case URI.decode(encoded_id) do
      decoded when decoded != "" ->
        if String.contains?(decoded, "/"), do: {:error, :not_found}, else: {:ok, decoded}

      _invalid ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp decode_resource_id(_encoded_id), do: {:error, :not_found}

  defp resource_session_project(session_id, partition) do
    query =
      from(event in Backplane.Memory.Events.Event,
        where:
          event.host_id == ^partition.host_id and
            event.client_id == ^partition.partition_id and event.scope == ^partition.scope and
            event.namespace == ^partition.namespace and event.session_id == ^session_id,
        where: not is_nil(event.project),
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 1,
        select: event.project
      )

    case Application.fetch_env!(:backplane_memory, :repo).one(query) do
      project when is_binary(project) and project != "" -> {:ok, project}
      _ -> {:error, :not_found}
    end
  end

  defp resource_arguments("memory://memories/latest"), do: %{"limit" => 10}
  defp resource_arguments("memory://crystals/latest"), do: %{"limit" => 10}
  defp resource_arguments("memory://sessions/active"), do: %{"limit" => 100}
  defp resource_arguments("memory://audit/recent"), do: %{"limit" => 50}
  defp resource_arguments(_uri), do: %{}

  defp resource_result("memory://status", %{stats: stats}),
    do: %{status: "ok", memory_stats: stats}

  defp resource_result(_uri, result), do: result

  defp lesson_resource(lesson) do
    %{
      memory_id: lesson.id,
      kind: lesson.kind,
      rule: lesson.content,
      project: lesson.project,
      session_id: lesson.session_id,
      status: lesson.lifecycle_state,
      confidence: lesson.confidence,
      evidence_ids: lesson.evidence_ids,
      source_refs:
        Enum.map(lesson.source_refs, fn
          %_{} = source_ref -> Map.from_struct(source_ref)
          source_ref when is_map(source_ref) -> source_ref
        end)
    }
  end

  # ──────────────────────────────────────────────
  # Prompts
  # ──────────────────────────────────────────────

  @impl true
  def prompts do
    Backplane.Memory.Prompts.descriptors()
  end

  @impl true
  def get_prompt(name, args, auth), do: Backplane.Memory.Prompts.get(name, args, auth)

  def get_prompt(name, args),
    do: get_prompt(name, args, %{kind: :open, client_id: nil, scopes: [], subject: nil})

  # ──────────────────────────────────────────────
  # Existing handlers (unchanged)
  # ──────────────────────────────────────────────

  def handle_remember(_args), do: {:error, :unauthorized}

  def handle_remember(%{"content" => content} = args, auth) when is_binary(content) do
    with :ok <- validate_remember_args(args),
         {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         :ok <- validate_remember_scope(args["scope"], partition.scope) do
      do_handle_remember(content, args, partition)
    end
  end

  def handle_remember(_args, _auth),
    do: {:error, "content is required and must be a string"}

  def handle_lifecycle_context(args, auth) when is_map(args) do
    with {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         :ok <- validate_lifecycle_context_args(args) do
      context = build_lifecycle_context(args, partition)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok,
       %{
         kind: args["kind"],
         context: context,
         source_revision: context_revision(context),
         generated_at: DateTime.to_iso8601(now),
         expires_at:
           now
           |> DateTime.add(@lifecycle_context_ttl_seconds, :second)
           |> DateTime.to_iso8601(),
         cached: false,
         stale: false
       }}
    end
  end

  def handle_lifecycle_context(_args, _auth), do: {:error, :invalid_arguments}

  defp build_lifecycle_context(args, partition) do
    context_module = Application.get_env(:backplane_memory, :context_module, Context)

    context_module.build(args["project"], args["session_id"],
      include_profile: true,
      kind: lifecycle_kind(args["kind"]),
      scope: partition.scope,
      host_id: partition.host_id,
      client_id: partition.partition_id,
      namespace: partition.namespace
    )
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp lifecycle_kind("session_start"), do: :session_start
  defp lifecycle_kind("pre_compact"), do: :pre_compact

  defp validate_lifecycle_context_args(args) do
    allowed = ~w(kind session_id project agent_id)

    cond do
      not Enum.all?(Map.keys(args), &(&1 in allowed)) -> {:error, :invalid_arguments}
      args["kind"] not in ["session_start", "pre_compact"] -> {:error, :invalid_kind}
      not non_empty_string?(args["session_id"]) -> {:error, :invalid_session_id}
      not non_empty_string?(args["project"]) -> {:error, :invalid_project}
      invalid_optional_agent_id?(args) -> {:error, :invalid_arguments}
      true -> :ok
    end
  end

  defp invalid_optional_agent_id?(%{"agent_id" => agent_id}),
    do: not non_empty_string?(agent_id)

  defp invalid_optional_agent_id?(_args), do: false

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp context_revision(nil), do: nil

  defp context_revision(context) do
    :crypto.hash(:sha256, context)
    |> Base.encode16(case: :lower)
  end

  defp do_handle_remember(content, args, partition) do
    opts =
      [
        type: args["type"] || "semantic",
        scope: args["scope"] || partition.scope,
        agent_id: args["agent_id"] || "",
        host_id: partition.host_id,
        client_id: partition.partition_id,
        namespace: partition.namespace,
        session_id: args["session_id"],
        tags: args["tags"] || [],
        metadata: args["metadata"] || %{}
      ]
      |> add_direct_idempotency(args, partition.partition_id)

    case Memories.remember(content, opts) do
      {:ok, mem} ->
        case args["facets"] do
          facets when is_list(facets) and facets != [] ->
            case Backplane.Memory.Facets.tag(mem.id, facets) do
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

  defp validate_remember_args(args) do
    allowed = ~w(content type scope agent_id idempotency_key session_id tags metadata facets)
    if Enum.all?(Map.keys(args), &(&1 in allowed)), do: :ok, else: {:error, :invalid_arguments}
  end

  defp validate_remember_scope(nil, _allowed_scope), do: :ok
  defp validate_remember_scope(scope, scope), do: :ok
  defp validate_remember_scope(_scope, _allowed_scope), do: {:error, :unauthorized}

  defp do_handle_recall(%{"query" => query} = args) when is_binary(query) do
    if Config.recall_v2_enabled?(),
      do: do_handle_recall_v2(query, args),
      else: do_handle_recall_legacy(query, args)
  end

  defp do_handle_recall(_), do: {:error, "query is required and must be a string"}

  defp do_handle_lesson_save(args, auth) when is_map(args) do
    allowed = ~w(rule context project session_id idempotency_key request_id correlation_id)

    with true <- Enum.all?(Map.keys(args), &(&1 in allowed)),
         {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         {:ok, actor} <- authenticated_actor(auth),
         {:ok, request_id} <- bounded_trace_id(args["request_id"] || Ecto.UUID.generate()),
         {:ok, correlation_id} <- bounded_trace_id(args["correlation_id"] || request_id) do
      attrs = Map.take(args, ~w(rule context project session_id idempotency_key))
      exact_partition = Map.put(partition, :client_id, partition.partition_id)

      case Lessons.save(attrs, exact_partition, %{
             actor: actor,
             request_id: request_id,
             correlation_id: correlation_id
           }) do
        {:ok, lesson} ->
          {:ok,
           %{
             memory_id: lesson.memory_id,
             status: lesson.status,
             source_kind: lesson.source_kind,
             created_at: lesson.created_at
           }}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, format_changeset(changeset)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  defp do_handle_lesson_save(_args, _auth), do: {:error, :invalid_arguments}

  defp authenticated_actor(%{subject: subject}) when is_binary(subject) and subject != "",
    do: {:ok, subject}

  defp authenticated_actor(%{client_id: client_id}) when is_binary(client_id) and client_id != "",
    do: {:ok, client_id}

  defp authenticated_actor(_auth), do: {:error, :unauthorized}

  defp bounded_trace_id(value) when is_binary(value) and byte_size(value) in 1..1024 do
    case String.trim(value) do
      "" -> {:error, :invalid_arguments}
      normalized -> {:ok, normalized}
    end
  end

  defp bounded_trace_id(_value), do: {:error, :invalid_arguments}

  defp do_handle_lesson_recall(%{"query" => query} = args) when is_binary(query) do
    opts = [limit: args["limit"] || 10, project: args["project"]]

    case Lessons.recall(query, partition_from_args(args), opts) do
      {:ok, candidates} ->
        {:ok,
         %{
           results:
             Enum.map(candidates, fn candidate ->
               %{
                 memory_id: candidate.id,
                 kind: candidate.kind,
                 rule: candidate.content,
                 project: candidate.project,
                 status: candidate.lifecycle_state,
                 confidence: candidate.confidence,
                 evidence_ids: candidate.evidence_ids,
                 source_refs: candidate.source_refs
               }
             end)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_handle_lesson_recall(_args), do: {:error, :invalid_arguments}

  defp do_handle_lesson_strengthen(args, auth) do
    source_keys =
      ~w(source_event_id source_observation_id source_summary_id source_request_id source_session_id)

    allowed = ~w(memory_id mode idempotency_key request_id correlation_id) ++ source_keys

    with true <- Enum.all?(Map.keys(args), &(&1 in allowed)),
         {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         {:ok, trace} <- lesson_trace(args, auth) do
      Lessons.strengthen(
        args["memory_id"],
        args["mode"],
        args["idempotency_key"],
        Map.take(args, source_keys),
        Map.put(partition, :client_id, partition.partition_id),
        trace
      )
      |> lesson_strengthen_result()
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  defp do_handle_lesson_promote(args, auth) do
    allowed = ~w(memory_id reason idempotency_key request_id correlation_id)

    with true <- Enum.all?(Map.keys(args), &(&1 in allowed)),
         {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         {:ok, trace} <- lesson_trace(args, auth),
         {:ok, lesson} <-
           Lessons.promote(
             args["memory_id"],
             args["reason"],
             args["idempotency_key"],
             Map.put(partition, :client_id, partition.partition_id),
             trace
           ) do
      {:ok, lesson_result(lesson)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp do_handle_lesson_archive(args, auth) do
    targets = %{"archive" => "archived", "reactivate" => "active", "dispute" => "disputed"}
    allowed = ~w(memory_id action reason idempotency_key request_id correlation_id)

    with true <- Enum.all?(Map.keys(args), &(&1 in allowed)),
         {:ok, target} <- Map.fetch(targets, args["action"]),
         {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         {:ok, trace} <- lesson_trace(args, auth),
         {:ok, lesson} <-
           Lessons.transition(
             args["memory_id"],
             target,
             args["reason"],
             args["idempotency_key"],
             Map.put(partition, :client_id, partition.partition_id),
             trace
           ) do
      {:ok, lesson_result(lesson)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_arguments}
    end
  end

  defp do_handle_crystallize(args, auth) when is_map(args) and is_map(auth) do
    allowed =
      ~w(source_kind session_id root_action_id allow_nonterminal request_id correlation_id)

    with true <- Enum.all?(Map.keys(args), &(&1 in allowed)),
         {:ok, partition} <- Backplane.Memory.Partition.resolve(auth),
         {:ok, actor} <- authenticated_actor(auth),
         {:ok, request_id} <- bounded_trace_id(args["request_id"] || Ecto.UUID.generate()),
         {:ok, correlation_id} <- bounded_trace_id(args["correlation_id"] || request_id),
         exact_partition = Map.put(partition, :client_id, partition.partition_id),
         {:ok, result, targets} <- crystallize_source(args, exact_partition) do
      :ok =
        Backplane.Memory.Audit.log("crystal.crystallize", actor, targets, %{
          request_id: request_id,
          correlation_id: correlation_id,
          host_id: exact_partition.host_id,
          client_id: exact_partition.client_id,
          scope: exact_partition.scope,
          namespace: exact_partition.namespace,
          source_kind: args["source_kind"],
          result: result.status
        })

      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp do_handle_crystallize(_args, _auth), do: {:error, :invalid_arguments}

  defp crystallize_source(%{"source_kind" => "session", "session_id" => session_id}, partition)
       when is_binary(session_id) do
    with {:ok, enqueue} <- Crystals.enqueue_session(session_id, partition) do
      result = %{
        status: enqueue.status,
        source_kind: "session",
        source_session_id: session_id,
        input_revision: enqueue.input_revision,
        job_id: if(enqueue.job, do: enqueue.job.id, else: nil)
      }

      {:ok, result, %{source_session_id: session_id}}
    end
  end

  defp crystallize_source(
         %{"source_kind" => "action_chain", "root_action_id" => root_action_id} = args,
         partition
       )
       when is_binary(root_action_id) do
    opts =
      if args["allow_nonterminal"] == true,
        do: [allow_nonterminal: true, authorized_override: true],
        else: []

    with {:ok, crystal} <- Crystals.build_action_chain(root_action_id, partition, opts) do
      {:ok, crystal_result(crystal), %{crystal_id: crystal.id, root_action_id: root_action_id}}
    end
  end

  defp crystallize_source(_args, _partition), do: {:error, :invalid_arguments}

  defp do_handle_crystal_get(%{"crystal_id" => id} = args) when is_binary(id) do
    with :ok <- strict_trusted_args(args, ~w(crystal_id)),
         {:ok, detail} <- Crystals.get(id, trusted_partition(args)) do
      {:ok, crystal_detail_result(detail)}
    end
  end

  defp do_handle_crystal_get(_args), do: {:error, :invalid_arguments}

  defp do_handle_crystal_list(args) when is_map(args) do
    with :ok <- strict_trusted_args(args, ~w(limit after)),
         {:ok, limit} <- bounded_limit(args["limit"], 20),
         :ok <- bounded_optional_string(args["after"], 4096),
         {:ok, page} <-
           Crystals.list(trusted_partition(args), limit: limit, after: args["after"]) do
      {:ok,
       %{
         results: Enum.map(page.entries, &crystal_result/1),
         next_cursor: page.next_cursor
       }}
    end
  end

  defp do_handle_crystal_list(_args), do: {:error, :invalid_arguments}

  defp do_handle_crystal_search(%{"query" => query} = args) when is_binary(query) do
    with :ok <- strict_trusted_args(args, ~w(query limit)),
         :ok <- bounded_non_empty_string(query, 4096),
         {:ok, limit} <- bounded_limit(args["limit"], 20),
         {:ok, crystals} <- Crystals.search(query, trusted_partition(args), limit: limit) do
      {:ok, %{results: Enum.map(crystals, &crystal_result/1)}}
    end
  end

  defp do_handle_crystal_search(_args), do: {:error, :invalid_arguments}

  defp strict_trusted_args(args, public_keys) do
    trusted_keys = ~w(host_id client_id scope namespace)

    if Enum.all?(Map.keys(args), &(&1 in public_keys or &1 in trusted_keys)),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp trusted_partition(args) do
    %{
      host_id: args["host_id"],
      client_id: args["client_id"],
      scope: args["scope"],
      namespace: args["namespace"]
    }
  end

  defp bounded_limit(nil, default), do: {:ok, default}
  defp bounded_limit(value, _default) when is_integer(value) and value in 1..100, do: {:ok, value}

  defp bounded_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_limit(integer, default)
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp bounded_limit(_value, _default), do: {:error, :invalid_arguments}

  defp bounded_optional_string(nil, _max), do: :ok
  defp bounded_optional_string(value, max), do: bounded_non_empty_string(value, max)

  defp bounded_non_empty_string(value, max)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max do
    if String.trim(value) == "", do: {:error, :invalid_arguments}, else: :ok
  end

  defp bounded_non_empty_string(_value, _max), do: {:error, :invalid_arguments}

  defp crystal_detail_result(detail) do
    detail.crystal
    |> crystal_result()
    |> Map.merge(%{
      source_action_ids: detail.source_action_ids,
      source_event_ids: detail.source_event_ids,
      source_summary_ids: detail.source_summary_ids,
      lesson_memory_ids: detail.lesson_memory_ids
    })
  end

  defp crystal_result(crystal) do
    %{
      crystal_id: crystal.id,
      memory_id: crystal.memory_id,
      source_kind: crystal.source_kind,
      source_session_id: crystal.source_session_id,
      title: crystal.title,
      project: crystal.project,
      narrative: crystal.narrative,
      key_outcomes: crystal.key_outcomes,
      decisions: crystal.decisions,
      files_affected: crystal.files_affected,
      unresolved_items: crystal.unresolved_items,
      processing_version: crystal.processing_version,
      prompt_version: crystal.prompt_version,
      model: crystal.model,
      input_revision: crystal.input_revision,
      output_revision: crystal.output_revision,
      status: crystal.status,
      last_error: crystal.last_error,
      started_at: crystal.started_at,
      completed_at: crystal.completed_at,
      inserted_at: crystal.inserted_at,
      updated_at: crystal.updated_at
    }
  end

  defp lesson_trace(args, auth) do
    with {:ok, actor} <- authenticated_actor(auth),
         {:ok, request_id} <- bounded_trace_id(args["request_id"] || Ecto.UUID.generate()),
         {:ok, correlation_id} <- bounded_trace_id(args["correlation_id"] || request_id) do
      {:ok, %{actor: actor, request_id: request_id, correlation_id: correlation_id}}
    end
  end

  defp lesson_result(lesson),
    do: %{memory_id: lesson.memory_id, status: lesson.status, source_kind: lesson.source_kind}

  defp lesson_strengthen_result({:ok, %{lesson: lesson, applied: applied}}),
    do:
      {:ok,
       lesson_result(lesson)
       |> Map.merge(%{
         applied: applied,
         reinforcement_count: lesson.reinforcement_count,
         last_reinforced_at: lesson.last_reinforced_at,
         last_applied_at: lesson.last_applied_at
       })}

  defp lesson_strengthen_result({:error, reason}), do: {:error, reason}

  defp do_handle_recall_legacy(query, args) do
    opts =
      [limit: args["limit"] || 10]
      |> add_if(args, "scope", :scope)
      |> add_if(args, "host_id", :host_id)
      |> add_if(args, "client_id", :client_id)
      |> add_if(args, "namespace", :namespace)
      |> add_if(args, "agent_id", :agent_id)
      |> add_if(args, "tag", :tag)

    case args["facets"] do
      facets when is_list(facets) and facets != [] ->
        facet_ids = Backplane.Memory.Facets.query(facets)

        if facet_ids == [] do
          {:ok, %{results: []}}
        else
          {:ok, results} = Search.hybrid_recall(query, opts)
          id_set = MapSet.new(facet_ids)
          filtered = Enum.filter(results, fn r -> MapSet.member?(id_set, r.id) end)
          {:ok, %{results: filtered}}
        end

      _ ->
        {:ok, results} = Search.hybrid_recall(query, opts)
        {:ok, %{results: results}}
    end
  end

  defp do_handle_recall_v2(query, args) do
    allowed =
      ~w(query limit scope host_id client_id namespace project facets token_budget temporal_hints entity_hints include_working channel_weights __trusted_internal__)

    cond do
      Map.has_key?(args, "agent_id") or Map.has_key?(args, "tag") ->
        {:error, :unsupported_recall_v2_filter}

      Map.keys(args) -- allowed != [] ->
        {:error, :invalid_arguments}

      true ->
        plan = %{
          query: query,
          host_id: args["host_id"],
          client_id: args["client_id"],
          scope: args["scope"],
          namespace: args["namespace"],
          project: args["project"],
          facets: args["facets"] || [],
          temporal_hints: args["temporal_hints"],
          entity_hints: args["entity_hints"] || [],
          include_working: args["include_working"] || false,
          channel_weights: args["channel_weights"] || Config.recall_channel_weights(),
          token_budget: args["token_budget"] || Config.recall_token_budget()
        }

        limit = args["limit"] || 10

        Pipeline.run(plan,
          request_id: Ecto.UUID.generate(),
          correlation_id: Ecto.UUID.generate(),
          post_fusion_opts: [limit: limit]
        )
    end
  end

  defp do_handle_list(args) when is_map(args) do
    opts =
      []
      |> add_if(args, "type", :type)
      |> add_if(args, "scope", :scope)
      |> add_if(args, "host_id", :host_id)
      |> add_if(args, "client_id", :client_id)
      |> add_if(args, "namespace", :namespace)
      |> add_if(args, "agent_id", :agent_id)
      |> add_if(args, "tag", :tag)
      |> add_if(args, "q", :q)
      |> Keyword.put(:limit, args["limit"] || 50)
      |> Keyword.put(:offset, args["offset"] || 0)

    rows =
      if args["__trusted_internal__"] do
        test_trusted_list(opts)
      else
        Memories.list(opts, partition_from_args(args))
      end

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

  defp do_handle_forget(%{"id" => id} = args) when is_binary(id) do
    result =
      if args["__trusted_internal__"] do
        test_trusted_forget(id)
      else
        Memories.forget(id, partition_from_args(args))
      end

    case result do
      :ok -> {:ok, %{id: id, status: "deleted"}}
      {:error, :not_found} -> {:error, "memory not found"}
      {:error, :provenance_retained} -> {:error, "memory provenance retained"}
    end
  end

  defp do_handle_forget(_), do: {:error, "id is required and must be a string"}

  defp do_handle_stats(args) when is_map(args) do
    rows =
      if args["__trusted_internal__"] do
        test_trusted_list(limit: 10_000)
      else
        Memories.list([limit: 10_000], partition_from_args(args))
      end

    stats =
      rows
      |> Enum.frequencies_by(& &1.memory_type)
      |> Enum.map(fn {memory_type, count} -> %{memory_type: memory_type, count: count} end)
      |> Enum.sort_by(& &1.memory_type)

    {:ok, %{stats: stats}}
  end

  defp do_handle_profile(%{"project" => project} = args) when is_binary(project) do
    case Profiles.get_or_build(project, partition_from_args(args)) do
      {:ok, p} ->
        {:ok,
         %{
           project: p.project,
           top_concepts: p.top_concepts,
           top_files: p.top_files,
           patterns: p.patterns,
           session_count: p.session_count,
           total_observations: p.total_observations,
           updated_at: p.updated_at
         }}

      {:building, nil} ->
        {:ok, %{status: "building"}}
    end
  end

  defp do_handle_profile(_), do: {:error, "project is required"}

  defp do_handle_profile_refresh(%{"project" => project} = args) when is_binary(project) do
    Backplane.Memory.Workers.ProfileBuildWorker.enqueue(project, partition_from_args(args))
    {:ok, %{status: "queued", project: project}}
  end

  defp do_handle_profile_refresh(_), do: {:error, "project is required"}

  defp do_handle_expand_query(%{"query" => query}) when is_binary(query) do
    llm_module = Application.get_env(:backplane_memory, :llm_module, Backplane.Memory.LLM)

    case llm_module.expand_query(query) do
      {:ok, expansions} -> {:ok, %{query: query, expansions: expansions}}
      {:skip, _} -> {:ok, %{query: query, expansions: [query], note: "LLM not configured"}}
    end
  end

  defp do_handle_expand_query(_), do: {:error, "query is required"}

  defp do_handle_file_history(%{"files" => files} = args) when is_list(files) do
    opts =
      [
        limit: args["limit"] || 50,
        host_id: args["host_id"],
        client_id: args["client_id"],
        scope: args["scope"],
        namespace: args["namespace"]
      ]
      |> then(fn o ->
        case args["exclude_session"] do
          s when is_binary(s) and s != "" -> Keyword.put(o, :exclude_session, s)
          _ -> o
        end
      end)

    rows = Backplane.Memory.Observations.file_history(files, opts)

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

  defp do_handle_file_history(_), do: {:error, "files is required and must be an array"}

  defp do_handle_facet_tag(%{"memory_id" => id, "facets" => facets}) do
    case Backplane.Memory.Facets.tag(id, facets) do
      {:ok, count} -> {:ok, %{tagged: count}}
      {:error, {:unknown_dimension, dim}} -> {:error, "unknown facet dimension: #{dim}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_handle_facet_tag(_), do: {:error, "memory_id and facets are required"}

  defp do_handle_facet_query(%{"facets" => facets} = args) when is_list(facets) do
    limit = args["limit"] || 20
    memory_ids = Backplane.Memory.Facets.query(facets)

    if memory_ids == [] do
      {:ok, %{results: []}}
    else
      repo = Application.fetch_env!(:backplane_memory, :repo)

      rows =
        repo.all(
          from(m in Backplane.Memory.Memories.Memory,
            where:
              m.id in ^memory_ids and is_nil(m.deleted_at) and
                m.host_id == ^args["host_id"] and m.client_id == ^args["client_id"] and
                m.scope == ^args["scope"] and m.namespace == ^args["namespace"],
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

  defp do_handle_facet_query(_), do: {:error, "facets array is required"}

  defp do_handle_team_share(%{"memory_id" => memory_id, "team_id" => team_id} = args)
       when is_binary(memory_id) and is_binary(team_id) do
    case Memories.team_share(memory_id, team_id, partition_from_args(args)) do
      :ok -> {:ok, %{memory_id: memory_id, namespace: "team:#{team_id}"}}
      {:error, :not_found} -> {:error, "memory not found"}
    end
  end

  defp do_handle_team_share(_), do: {:error, "memory_id and team_id are required"}

  defp do_handle_team_feed(%{"team_id" => team_id} = args) when is_binary(team_id) do
    limit = args["limit"] || 20
    namespace = "team:#{team_id}"
    repo = Application.fetch_env!(:backplane_memory, :repo)

    rows =
      repo.all(
        from(m in Backplane.Memory.Memories.Memory,
          where:
            m.namespace == ^namespace and is_nil(m.deleted_at) and
              m.host_id == ^args["host_id"] and m.client_id == ^args["client_id"] and
              m.scope == ^args["scope"],
          order_by: [desc: m.inserted_at],
          limit: ^limit
        )
      )

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

  defp do_handle_team_feed(_), do: {:error, "team_id is required"}

  defp do_handle_lease(%{"action_id" => action_id, "agent_id" => agent_id} = args)
       when is_binary(action_id) and is_binary(agent_id) do
    ttl = args["ttl_seconds"] || 300

    case Lease.acquire(action_id, agent_id, ttl, partition_from_args(args)) do
      {:ok, lease_id} ->
        {:ok, %{lease_id: lease_id, action_id: action_id}}

      {:error, %{held_by: held_by, expires_at: expires_at}} ->
        {:error, "lease held by #{held_by} until #{DateTime.to_iso8601(expires_at)}"}

      {:error, :not_found} ->
        {:error, "failed to acquire lease"}
    end
  end

  defp do_handle_lease(_), do: {:error, "action_id and agent_id are required"}

  defp do_handle_signal_send(
         %{
           "sender_agent_id" => sender,
           "recipient_agent_id" => recipient,
           "topic" => topic
         } = args
       )
       when is_binary(sender) and is_binary(recipient) and is_binary(topic) do
    payload = args["payload"] || %{}

    case Signal.send_signal(sender, recipient, topic, payload, partition_from_args(args)) do
      {:ok, sig} -> {:ok, %{id: sig.id, sent_at: sig.sent_at}}
      {:error, changeset} -> {:error, format_changeset(changeset)}
    end
  end

  defp do_handle_signal_send(_),
    do: {:error, "sender_agent_id, recipient_agent_id, and topic are required"}

  defp do_handle_signal_read(%{"agent_id" => agent_id} = args) when is_binary(agent_id) do
    topic = args["topic"]
    limit = args["limit"] || 20

    case Signal.read_signals(agent_id, topic, limit, partition_from_args(args)) do
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

  defp do_handle_signal_read(_), do: {:error, "agent_id is required"}

  defp do_handle_action_create(%{"title" => title} = args) when is_binary(title) do
    edges = args["edges"] || []

    attrs =
      %{"title" => title}
      |> maybe_put(args, "description")
      |> maybe_put(args, "priority")
      |> maybe_put(args, "project")
      |> maybe_put(args, "tags")
      |> maybe_put(args, "created_by")
      |> maybe_put(args, "source_observation_ids")
      |> maybe_put(args, "source_memory_ids")
      |> maybe_put(args, "source_session_ids")
      |> maybe_put(args, "source_lesson_ids")
      |> maybe_put(args, "source_crystal_ids")

    case Action.create(attrs, edges, partition_from_args(args)) do
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

  defp do_handle_action_create(_), do: {:error, "title is required"}

  defp do_handle_action_update(%{"action_id" => action_id, "status" => status} = args)
       when is_binary(action_id) and is_binary(status) do
    case Action.update_status(action_id, status, partition_from_args(args)) do
      :ok -> {:ok, %{action_id: action_id, status: status}}
      {:error, :not_found} -> {:error, "action not found"}
      {:error, {:invalid_status, s}} -> {:error, "invalid status: #{s}"}
    end
  end

  defp do_handle_action_update(_), do: {:error, "action_id and status are required"}

  defp do_handle_frontier(args) when is_map(args) do
    project = args["project"]
    actions = Action.frontier(project, partition_from_args(args))

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

  defp do_handle_next(args) when is_map(args) do
    project = args["project"]

    case Action.next(project, partition_from_args(args)) do
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

  defp do_handle_smart_search(%{"query" => query} = args) when is_binary(query) do
    limit = args["limit"] || 5

    {:ok, results} =
      Search.hybrid_recall(query,
        limit: limit,
        scope: args["scope"],
        host_id: args["host_id"],
        client_id: args["client_id"],
        namespace: args["namespace"]
      )

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
  end

  defp do_handle_smart_search(_), do: {:error, "query is required"}

  defp do_handle_sessions(args) when is_map(args) do
    with {:ok, sessions} <-
           ReadModels.sessions(
             limit: args["limit"] || 20,
             offset: args["offset"] || 0,
             project: args["project"],
             host_id: args["host_id"],
             client_id: args["client_id"],
             scope: args["scope"],
             namespace: args["namespace"],
             session_id: args["session_id"]
           ) do
      {:ok, %{sessions: sessions}}
    end
  end

  defp do_handle_patterns(args) when is_map(args) do
    with {:ok, top_tools} <-
           ReadModels.patterns(
             project: args["project"],
             session_id: args["session_id"],
             host_id: args["host_id"],
             client_id: args["client_id"],
             scope: args["scope"],
             namespace: args["namespace"],
             limit: args["limit"] || 10,
             offset: args["offset"] || 0
           ) do
      {:ok, %{top_tools: top_tools}}
    end
  end

  defp do_handle_timeline(args) when is_map(args) do
    with {:ok, timeline} <-
           ReadModels.timeline(
             project: args["project"],
             session_id: args["session_id"],
             host_id: args["host_id"],
             client_id: args["client_id"],
             scope: args["scope"],
             namespace: args["namespace"],
             event_type: args["event_type"],
             tool_name: args["tool_name"],
             minimum_importance: args["minimum_importance"],
             is_error: args["is_error"],
             file_path: args["file_path"],
             occurred_from: args["occurred_from"],
             occurred_to: args["occurred_to"],
             limit: args["limit"] || 50,
             offset: args["offset"] || 0
           ) do
      {:ok, %{timeline: timeline}}
    end
  end

  defp do_handle_recall_explain(%{"recall_run_id" => recall_run_id} = args) do
    with {:ok, run, candidates} <- RecallStore.get(recall_run_id, partition_from_args(args)) do
      {:ok,
       %{
         run: serialize_recall_run(run),
         candidates: Enum.map(candidates, &serialize_recall_candidate/1)
       }}
    end
  end

  defp do_handle_recall_explain(_args), do: {:error, :invalid_arguments}

  defp serialize_recall_run(run) do
    Map.take(run, [
      :id,
      :request_id,
      :correlation_id,
      :normalized_query,
      :query_plan,
      :filters,
      :channel_weights,
      :channel_availability,
      :channel_errors,
      :token_budget,
      :tokens_used,
      :result_count,
      :latency_ms,
      :reranker_status,
      :reranker_error_class,
      :status,
      :failure_class,
      :completed_at,
      :inserted_at
    ])
  end

  defp serialize_recall_candidate(candidate) do
    candidate
    |> Map.take([
      :candidate_id,
      :candidate_kind,
      :memory_type,
      :source_ids,
      :source_refs,
      :channel_scores,
      :fts_rank,
      :vector_rank,
      :graph_rank,
      :fts_score,
      :vector_score,
      :graph_score,
      :rrf_score,
      :lifecycle_score,
      :reranker_score,
      :final_score,
      :pre_reranker_rank,
      :post_reranker_rank,
      :selected,
      :rejection_reason,
      :token_estimate
    ])
    |> Map.update!(:source_refs, &Map.get(&1, "refs", []))
  end

  defp do_handle_activity_summary(args) when is_map(args) do
    partition = partition_from_args(args)

    with {:ok, opts} <- activity_options(args),
         {:ok, summary} <- Activity.summary(partition, opts) do
      audit_partition_read("memory.activity.summary", partition, [], %{
        "date_from" => Date.to_iso8601(summary.date_from),
        "date_to" => Date.to_iso8601(summary.date_to)
      })

      {:ok, %{summary: summary}}
    end
  end

  defp do_handle_replay_sessions(args) when is_map(args) do
    partition = partition_from_args(args)

    with {:ok, result} <-
           Replay.sessions(partition,
             limit: args["limit"] || 20,
             offset: args["offset"] || 0
           ) do
      ids = Enum.map(result.sessions, & &1.session_id)
      audit_partition_read("memory.replay.sessions", partition, ids, %{"count" => length(ids)})
      {:ok, result}
    end
  end

  defp do_handle_replay_load(%{"session_id" => session_id} = args) when is_binary(session_id) do
    partition = partition_from_args(args)
    limit = min(args["limit"] || 50, min(Config.replay_max_events(), 100))
    opts = [limit: limit] |> maybe_keyword(:cursor, args["cursor"])

    with {:ok, result} <- Replay.load(partition, session_id, opts) do
      audit_partition_read("memory.replay.load", partition, [session_id], %{
        "event_count" => length(result.events),
        "has_next_page" => not is_nil(result.next_cursor)
      })

      {:ok, result}
    end
  end

  defp do_handle_replay_load(_args), do: {:error, :invalid_arguments}

  defp do_handle_replay_import(args) when is_map(args) do
    partition = partition_from_args(args)
    request_id = args["request_id"] || Ecto.UUID.generate()

    payload = %{
      "protocol" => "host_import.v1",
      "request_id" => request_id,
      "profile" => args["profile"],
      "integration" => args["integration"] || "claude_code",
      "max_files" => Config.replay_import_max_files(),
      "max_entries" => Config.replay_import_max_entries(),
      "max_bytes" => Config.replay_import_max_bytes()
    }

    case replay_import_dispatcher().call_local_tool(
           partition.host_id,
           "memory.replay_import",
           payload,
           30_000
         ) do
      {:ok, result} ->
        safe = sanitize_import_dispatch_result(result, request_id)
        audit_partition_read("memory.replay.import_dispatched", partition, [], safe)
        {:ok, safe}

      {:error, reason} when reason in [:not_connected, :timeout] ->
        {:error, :host_unavailable}

      {:error, _reason} ->
        {:error, :import_dispatch_failed}
    end
  end

  defp do_handle_export(args) when is_map(args) do
    scope = args["scope"]
    partition = partition_from_args(args)

    rows =
      Memories.list([scope: scope, limit: 10_000], partition)

    request_id = Ecto.UUID.generate()

    :ok =
      Backplane.Memory.Audit.log(
        "memory.export",
        args["agent_id"] || partition.client_id || "system",
        Enum.map(rows, & &1.id),
        string_partition(partition)
        |> Map.merge(%{
          "request_id" => request_id,
          "correlation_id" => request_id,
          "correlation_ids" => [request_id],
          "result" => "exported",
          "memory_count" => length(rows)
        })
      )

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

  defp do_handle_relations(%{"entity" => entity} = args) when is_binary(entity) do
    depth = args["depth"] || 1

    case Backplane.Memory.Graph.BFS.query(entity, depth, nil, partition_from_args(args)) do
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

  defp do_handle_relations(_), do: {:error, "entity is required"}

  defp do_handle_compress_file(%{
         "file_path" => path,
         "agent_id" => agent_id,
         "host_id" => host_id,
         "client_id" => client_id,
         "scope" => scope,
         "namespace" => namespace
       })
       when is_binary(path) and is_binary(agent_id) and is_binary(host_id) do
    rows =
      Backplane.Memory.Observations.file_history([path],
        limit: 200,
        host_id: host_id,
        client_id: client_id,
        scope: scope,
        namespace: namespace
      )

    inputs = compression_inputs(rows)

    if inputs == [] do
      {:ok, %{status: "no_observations", file_path: path}}
    else
      summary =
        inputs
        |> Enum.map(&elem(&1, 1))
        |> Enum.join("\n")

      content = "File summary for #{path}:\n#{summary}"

      case Memories.remember(content,
             type: "semantic",
             scope: scope,
             agent_id: agent_id,
             host_id: host_id,
             client_id: client_id,
             namespace: namespace,
             tags: ["file_summary", path],
             idempotency_scope: "memory-tool:compress-file",
             idempotency_key: compression_idempotency_key(path, host_id, agent_id, inputs),
             evidence: compression_evidence(inputs, host_id, agent_id)
           ) do
        {:ok, mem} ->
          {:ok, %{status: "compressed", memory_id: mem.id, file_path: path}}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp do_handle_compress_file(_),
    do: {:error, "file_path, agent_id, and host_id are required"}

  defp compression_inputs(rows) do
    {inputs, _remaining} =
      Enum.reduce_while(rows, {[], 4_000}, fn observation, {inputs, remaining} ->
        separator_size = if inputs == [], do: 0, else: 1
        available = remaining - separator_size

        if available <= 0 do
          {:halt, {inputs, remaining}}
        else
          contribution = String.slice(observation.content, 0, available)
          updated = [{observation, contribution} | inputs]
          remaining = available - String.length(contribution)

          if String.length(contribution) < String.length(observation.content) do
            {:halt, {updated, remaining}}
          else
            {:cont, {updated, remaining}}
          end
        end
      end)

    Enum.reverse(inputs)
  end

  defp compression_idempotency_key(path, host_id, agent_id, inputs) do
    revision =
      inputs
      |> Enum.map_join("\n", fn {observation, _contribution} -> observation.id end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Enum.join([@file_compression_processing_version, path, host_id, agent_id, revision], ":")
  end

  defp compression_evidence(inputs, host_id, agent_id) do
    Enum.map(inputs, fn {observation, contribution} ->
      %{
        source_observation_id: observation.id,
        session_id: observation.session_id,
        agent_id: agent_id,
        host_id: host_id,
        evidence_kind: "derives",
        support_score: 1.0,
        excerpt: String.slice(contribution, 0, 1_000)
      }
    end)
  end

  defp do_handle_audit(args) when is_map(args) do
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

    partition = partition_from_args(args)

    entries =
      partition
      |> Backplane.Memory.Audit.list(opts)
      |> Enum.map(&serialize_audit_entry/1)

    {:ok, %{entries: entries}}
  end

  defp do_handle_governance_delete(%{"memory_id" => memory_id} = args)
       when is_binary(memory_id) do
    actor = "system"
    reason = args["reason"] || "governance_delete"
    hard_delete = Backplane.Settings.get("memory.hard_delete_enabled") == "true"
    repo = Application.fetch_env!(:backplane_memory, :repo)

    transaction =
      try do
        repo.transaction(fn ->
          forget_result =
            if args["__trusted_internal__"] do
              test_trusted_forget(memory_id)
            else
              Memories.forget(memory_id, partition_from_args(args))
            end

          case forget_result do
            :ok ->
              Backplane.Memory.Audit.log(
                "governance_delete",
                actor,
                %{"memory_id" => memory_id},
                Map.merge(
                  %{"reason" => reason, "hard_delete" => hard_delete},
                  string_partition(partition_from_args(args))
                )
              )

              status = if hard_delete, do: "hard_deleted", else: "soft_deleted"
              %{memory_id: memory_id, status: status, actor: actor}

            {:error, reason} ->
              repo.rollback(reason)
          end
        end)
      rescue
        Postgrex.Error -> {:error, :governance_audit_failed}
      end

    case transaction do
      {:ok, response} ->
        {:ok, response}

      {:error, :not_found} ->
        {:error, "memory not found"}

      {:error, :provenance_retained} ->
        partition = governance_audit_partition(args, memory_id)

        Backplane.Memory.Audit.log(
          "hard_delete",
          actor,
          [memory_id],
          Map.merge(
            %{
              "request_id" => Ecto.UUID.generate(),
              "result" => "denied",
              "reason" => "provenance_retained"
            },
            string_partition(partition)
          )
        )

        {:error, "memory provenance retained"}

      {:error, :governance_audit_failed} ->
        {:error, "governance audit failed"}
    end
  end

  defp do_handle_governance_delete(_), do: {:error, "memory_id is required"}

  defp do_handle_diagnose(args) do
    alias Backplane.Memory.Embedding.CircuitBreaker
    partition = partition_from_args(args)

    {:ok, %{stats: stats}} = do_handle_stats(args)

    repo = Application.fetch_env!(:backplane_memory, :repo)

    lease_count =
      repo.aggregate(
        from(l in Backplane.Memory.Coordination.Lease,
          where:
            l.host_id == ^partition.host_id and l.client_id == ^partition.client_id and
              l.scope == ^partition.scope and l.namespace == ^partition.namespace
        ),
        :count,
        :id
      )

    processing = Backplane.Memory.Operations.Health.snapshot(partition)

    {:ok,
     %{
       status: "ok",
       circuit_breaker: to_string(CircuitBreaker.state()),
       memory_stats: stats,
       active_leases: lease_count,
       processing: processing
     }}
  end

  defp do_handle_heal(%{"kind" => _kind} = args) do
    Backplane.Memory.Operations.Repair.run(
      args,
      partition_from_args(args),
      "system:memory-heal"
    )
  end

  defp do_handle_heal(args) do
    alias Backplane.Memory.Embedding.CircuitBreaker
    alias Backplane.Memory.Audit
    repo = Application.fetch_env!(:backplane_memory, :repo)
    now = DateTime.utc_now()
    partition = partition_from_args(args)

    {:ok, deleted} =
      repo.transaction(fn ->
        query =
          from(l in Backplane.Memory.Coordination.Lease,
            where:
              l.expires_at < ^now and l.host_id == ^partition.host_id and
                l.client_id == ^partition.client_id and l.scope == ^partition.scope and
                l.namespace == ^partition.namespace
          )

        ids = repo.all(from(l in query, select: l.id))
        {deleted, _} = repo.delete_all(from(l in query, select: l.id))

        Audit.log("coordination.heal", "system", ids, %{
          host_id: partition.host_id,
          client_id: partition.client_id,
          scope: partition.scope,
          namespace: partition.namespace,
          expired_leases_cleared: deleted,
          result: "healed"
        })

        deleted
      end)

    CircuitBreaker.reset()

    {:ok, %{status: "healed", expired_leases_cleared: deleted, circuit_breaker: "closed"}}
  end

  # ──────────────────────────────────────────────
  # Extended tool handlers
  # ──────────────────────────────────────────────

  defp do_handle_graph_query(%{"entity" => entity} = args) when is_binary(entity) do
    depth = args["depth"] || 2
    relation = args["relation"]

    case Backplane.Memory.Graph.BFS.query(entity, depth, relation, partition_from_args(args)) do
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

  defp do_handle_graph_query(_), do: {:error, "entity is required"}

  defp do_handle_graph_stats(args) do
    {:ok, Backplane.Memory.Graph.stats(partition_from_args(args))}
  end

  defp do_handle_consolidate(%{"session_id" => session_id} = args) when is_binary(session_id) do
    # Enqueue a profile build as the consolidation mechanism
    Backplane.Memory.Workers.ProfileBuildWorker.enqueue(session_id, partition_from_args(args))
    {:ok, %{status: "queued", session_id: session_id}}
  end

  defp do_handle_consolidate(_), do: {:error, "session_id is required"}

  defp do_handle_verify(%{"memory_id" => memory_id} = args) when is_binary(memory_id) do
    verification =
      if args["__trusted_internal__"] do
        test_trusted_verify(memory_id)
      else
        Memories.verify(memory_id, partition_from_args(args))
      end

    case verification do
      {:ok, verification} ->
        mem = verification.memory

        {:ok,
         %{
           exists: true,
           memory_id: memory_id,
           memory_type: mem.memory_type,
           scope: mem.scope,
           lifecycle_state: verification.lifecycle_state,
           superseded_by: verification.superseded_by,
           relations: verification.relations,
           audit: verification.audit,
           evidence: verification.evidence,
           evidence_count: verification.evidence_count,
           access_count: verification.access_count,
           application_count: verification.application_count,
           supporting_count: verification.supporting_count,
           contradictory_evidence_count: verification.contradictory_evidence_count,
           contradiction_count: verification.contradiction_count,
           contradiction_relation_count: verification.contradiction_relation_count,
           source_diversity: verification.source_diversity
         }}

      {:error, :not_found} ->
        {:ok, %{exists: false, memory_id: memory_id}}
    end
  end

  defp do_handle_verify(_), do: {:error, "memory_id is required"}

  defp add_direct_idempotency(opts, %{"idempotency_key" => key}, partition_id)
       when is_binary(key) do
    opts ++ [idempotency_key: key, idempotency_scope: "direct:" <> partition_id]
  end

  defp add_direct_idempotency(opts, _args, _partition_id), do: opts

  defp do_handle_slot_read(%{"name" => name} = args) when is_binary(name) do
    case Backplane.Memory.Slots.read(name, partition_from_args(args)) do
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

  defp do_handle_slot_read(_), do: {:error, "name is required"}

  defp do_handle_slot_write(%{"name" => name, "content" => content} = args)
       when is_binary(name) and is_binary(content) do
    updated_by = args["updated_by"]

    case Backplane.Memory.Slots.write(name, content, updated_by, partition_from_args(args)) do
      {:ok, slot} ->
        {:ok, %{name: slot.name, updated_at: slot.updated_at}}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, format_changeset(cs)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_handle_slot_write(_), do: {:error, "name and content are required"}

  defp do_handle_slot_list(args) do
    slots = Backplane.Memory.Slots.list(partition_from_args(args))

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

  defp do_handle_enrich(%{"memory_id" => memory_id} = args) when is_binary(memory_id) do
    repo = Application.fetch_env!(:backplane_memory, :repo)

    partition = partition_from_args(args)

    query =
      from(m in Backplane.Memory.Memories.Memory,
        where:
          m.id == ^memory_id and m.host_id == ^partition.host_id and
            m.client_id == ^partition.client_id and m.scope == ^partition.scope and
            m.namespace == ^partition.namespace
      )

    case repo.one(query) do
      nil ->
        {:error, "memory not found"}

      mem ->
        new_tags = (mem.tags ++ (args["tags"] || [])) |> Enum.uniq()

        new_metadata =
          Map.merge(mem.metadata || %{}, args["metadata"] || %{})

        {1, _} =
          repo.update_all(
            query,
            set: [tags: new_tags, metadata: new_metadata]
          )

        {:ok, %{memory_id: memory_id, tags: new_tags}}
    end
  end

  defp do_handle_enrich(_), do: {:error, "memory_id is required"}

  defp do_handle_access_log(%{"memory_id" => memory_id} = args) when is_binary(memory_id) do
    repo = Application.fetch_env!(:backplane_memory, :repo)
    partition = partition_from_args(args)

    result =
      repo.one(
        from(m in Backplane.Memory.Memories.Memory,
          where:
            m.id == ^memory_id and m.host_id == ^partition.host_id and
              m.client_id == ^partition.client_id and m.scope == ^partition.scope and
              m.namespace == ^partition.namespace,
          select: %{
            id: m.id,
            access_count: m.access_count,
            application_count: m.application_count,
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

  defp do_handle_access_log(_), do: {:error, "memory_id is required"}

  defp do_handle_apply(
         %{
           "memory_id" => memory_id,
           "application_id" => application_id,
           "applied_by" => applied_by
         } = args
       ) do
    case Memories.record_application(
           memory_id,
           application_id,
           applied_by,
           partition_from_args(args)
         ) do
      {:ok, result} -> {:ok, Map.put(result, :memory_id, memory_id)}
      {:error, :not_found} -> {:error, "memory not found"}
      {:error, :not_applicable} -> {:error, "memory is not procedural"}
      {:error, :invalid_application} -> {:error, "invalid application"}
    end
  end

  defp do_handle_apply(_args),
    do: {:error, "memory_id, application_id, and applied_by are required"}

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  if Mix.env() == :test do
    defp test_trusted_list(opts), do: Memories.trusted_list(opts)
    defp test_trusted_forget(id), do: Memories.trusted_forget(id)
    defp test_trusted_verify(id), do: Memories.trusted_verify(id)

    defp governance_audit_partition(%{"__trusted_internal__" => true}, memory_id) do
      {:ok, memory} = Memories.trusted_get(memory_id)

      %{
        host_id: memory.host_id,
        client_id: memory.client_id,
        scope: memory.scope,
        namespace: memory.namespace
      }
    end

    defp governance_audit_partition(args, _memory_id), do: partition_from_args(args)
  else
    defp test_trusted_list(_opts), do: raise("trusted memory access is test-only")
    defp test_trusted_forget(_id), do: raise("trusted memory access is test-only")
    defp test_trusted_verify(_id), do: raise("trusted memory access is test-only")
    defp governance_audit_partition(args, _memory_id), do: partition_from_args(args)
  end

  defp partition_from_args(%{
         "host_id" => host_id,
         "client_id" => client_id,
         "scope" => scope,
         "namespace" => namespace
       })
       when is_binary(host_id) and is_binary(client_id) and is_binary(scope) and
              is_binary(namespace) do
    %{host_id: host_id, client_id: client_id, scope: scope, namespace: namespace}
  end

  defp partition_from_args(%{"__trusted_internal__" => true}) do
    %{host_id: nil, client_id: nil, scope: nil, namespace: nil}
  end

  defp partition_from_args(_args),
    do: raise(ArgumentError, "authenticated memory partition is required")

  defp string_partition(partition),
    do: Map.new(partition, fn {key, value} -> {Atom.to_string(key), value} end)

  defp activity_options(args) do
    with {:ok, date_from} <- optional_date(args["date_from"]),
         {:ok, date_to} <- optional_date(args["date_to"]) do
      opts =
        []
        |> maybe_keyword(:date_from, date_from)
        |> maybe_keyword(:date_to, date_to)
        |> maybe_keyword(:project, args["project"])
        |> maybe_keyword(:agent_id, args["agent_id"])
        |> maybe_keyword(:event_type, args["event_type"])

      {:ok, opts}
    end
  end

  defp optional_date(nil), do: {:ok, nil}

  defp optional_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_arguments}
    end
  end

  defp optional_date(_value), do: {:error, :invalid_arguments}

  defp maybe_keyword(opts, _key, nil), do: opts
  defp maybe_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp audit_partition_read(operation, partition, target_ids, metadata) do
    Audit.log(
      operation,
      partition.client_id,
      target_ids,
      string_partition(partition) |> Map.merge(metadata)
    )
  end

  defp replay_import_dispatcher,
    do: Application.get_env(:backplane_memory, :replay_import_dispatcher, AgentManage)

  defp sanitize_import_dispatch_result(result, request_id) when is_map(result) do
    result
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(
      ~w(batch_id status integration source_format source_path_fingerprint discovered_count imported_count duplicate_count rejected_count)
    )
    |> Map.put("request_id", request_id)
    |> Map.put("dispatched", true)
  end

  defp sanitize_import_dispatch_result(_result, request_id),
    do: %{"request_id" => request_id, "dispatched" => true}

  defp serialize_audit_entry(%{id: id} = entry) when is_binary(id) and byte_size(id) == 16 do
    case Ecto.UUID.load(id) do
      {:ok, canonical_id} -> %{entry | id: canonical_id}
      :error -> entry
    end
  end

  defp serialize_audit_entry(entry), do: entry

  defp maybe_put(map, args, key) do
    case args[key] do
      nil -> map
      val -> Map.put(map, key, val)
    end
  end

  defp uuid_array_schema do
    %{"type" => "array", "items" => %{"type" => "string", "format" => "uuid"}}
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
