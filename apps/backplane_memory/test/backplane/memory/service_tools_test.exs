defmodule Backplane.Memory.ServiceToolsTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Memories, Service}
  alias Backplane.Memory.Coordination.Action
  alias Backplane.Skills.Host

  @extended_tool_names ~w(
    memory::access_log
    memory::consolidate
    memory::crystallize
    memory::enrich
    memory::graph_query
    memory::graph_stats
    memory::lesson_archive
    memory::lesson_promote
    memory::lesson_strengthen
    memory::replay_import
    memory::slot_list
    memory::slot_read
    memory::slot_write
    memory::verify
  )

  @full_tool_contracts Map.new([
                         {"memory::activity_summary",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "agent_id" => %{"maxLength" => 512, "type" => "string"},
                              "date_from" => %{"format" => "date", "type" => "string"},
                              "date_to" => %{"format" => "date", "type" => "string"},
                              "event_type" => %{"maxLength" => 512, "type" => "string"},
                              "project" => %{"maxLength" => 512, "type" => "string"}
                            },
                            "type" => "object"
                          }},
                         {"memory::recall_explain",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "recall_run_id" => %{"format" => "uuid", "type" => "string"}
                            },
                            "required" => ["recall_run_id"],
                            "type" => "object"
                          }},
                         {"memory::replay_sessions",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "limit" => %{
                                "default" => 20,
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              },
                              "offset" => %{
                                "default" => 0,
                                "maximum" => 10_000,
                                "minimum" => 0,
                                "type" => "integer"
                              }
                            },
                            "type" => "object"
                          }},
                         {"memory::replay_load",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "cursor" => %{"maxLength" => 4096, "type" => "string"},
                              "limit" => %{
                                "default" => 50,
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              },
                              "session_id" => %{
                                "maxLength" => 512,
                                "minLength" => 1,
                                "type" => "string"
                              }
                            },
                            "required" => ["session_id"],
                            "type" => "object"
                          }},
                         {"memory::replay_import",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "integration" => %{
                                "default" => "claude_code",
                                "enum" => ["claude_code"],
                                "type" => "string"
                              },
                              "profile" => %{
                                "pattern" => "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$",
                                "type" => "string"
                              },
                              "request_id" => %{
                                "maxLength" => 128,
                                "minLength" => 1,
                                "type" => "string"
                              }
                            },
                            "required" => ["profile"],
                            "type" => "object"
                          }},
                         {"memory::crystallize",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "allow_nonterminal" => %{"default" => false, "type" => "boolean"},
                              "correlation_id" => %{"type" => "string"},
                              "request_id" => %{"type" => "string"},
                              "root_action_id" => %{"type" => "string"},
                              "session_id" => %{"type" => "string"},
                              "source_kind" => %{
                                "enum" => ["session", "action_chain"],
                                "type" => "string"
                              }
                            },
                            "required" => ["source_kind"],
                            "type" => "object"
                          }},
                         {"memory::crystal_get",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{"crystal_id" => %{"type" => "string"}},
                            "required" => ["crystal_id"],
                            "type" => "object"
                          }},
                         {"memory::crystal_list",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "after" => %{"maxLength" => 4096, "type" => "string"},
                              "limit" => %{
                                "default" => 20,
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              }
                            },
                            "type" => "object"
                          }},
                         {"memory::crystal_search",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "limit" => %{
                                "default" => 20,
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              },
                              "query" => %{"maxLength" => 4096, "type" => "string"}
                            },
                            "required" => ["query"],
                            "type" => "object"
                          }},
                         {"memory::access_log",
                          %{
                            "properties" => %{"memory_id" => %{"type" => "string"}},
                            "required" => ["memory_id"],
                            "type" => "object"
                          }},
                         {"memory::apply",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "application_id" => %{"type" => "string"},
                              "applied_by" => %{"type" => "string"},
                              "memory_id" => %{"type" => "string"}
                            },
                            "required" => ["memory_id", "application_id", "applied_by"],
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
                              "source_crystal_ids" => %{
                                "items" => %{"format" => "uuid", "type" => "string"},
                                "type" => "array"
                              },
                              "source_lesson_ids" => %{
                                "items" => %{"format" => "uuid", "type" => "string"},
                                "type" => "array"
                              },
                              "source_memory_ids" => %{
                                "items" => %{"format" => "uuid", "type" => "string"},
                                "type" => "array"
                              },
                              "source_observation_ids" => %{
                                "items" => %{"format" => "uuid", "type" => "string"},
                                "type" => "array"
                              },
                              "source_session_ids" => %{
                                "items" => %{"type" => "string"},
                                "type" => "array"
                              },
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
                         {"memory::heal",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "action" => %{
                                "enum" => [
                                  "promote",
                                  "activate",
                                  "archive",
                                  "dispute",
                                  "supersede"
                                ],
                                "type" => "string"
                              },
                              "date_from" => %{"format" => "date", "type" => "string"},
                              "date_to" => %{"format" => "date", "type" => "string"},
                              "idempotency_key" => %{"minLength" => 1, "type" => "string"},
                              "kind" => %{
                                "enum" => [
                                  "coordination",
                                  "failed_projections",
                                  "reembed",
                                  "graph",
                                  "profile",
                                  "activity",
                                  "summary",
                                  "crystal",
                                  "relation",
                                  "lesson",
                                  "dead_letter"
                                ],
                                "type" => "string"
                              },
                              "project" => %{"minLength" => 1, "type" => "string"},
                              "reason" => %{"minLength" => 1, "type" => "string"},
                              "resolution" => %{
                                "enum" => ["confirmed", "rejected"],
                                "type" => "string"
                              },
                              "session_id" => %{"minLength" => 1, "type" => "string"},
                              "target_id" => %{"minLength" => 1, "type" => "string"}
                            },
                            "type" => "object"
                          }},
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
                         {"memory::lesson_recall",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "limit" => %{"default" => 10, "type" => "integer"},
                              "project" => %{"type" => "string"},
                              "query" => %{"type" => "string"}
                            },
                            "required" => ["query"],
                            "type" => "object"
                          }},
                         {"memory::lesson_archive",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "action" => %{
                                "enum" => ["archive", "reactivate", "dispute"],
                                "type" => "string"
                              },
                              "correlation_id" => %{"type" => "string"},
                              "idempotency_key" => %{"type" => "string"},
                              "memory_id" => %{"type" => "string"},
                              "reason" => %{"type" => "string"},
                              "request_id" => %{"type" => "string"}
                            },
                            "required" => ["memory_id", "action", "reason", "idempotency_key"],
                            "type" => "object"
                          }},
                         {"memory::lesson_promote",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "correlation_id" => %{"type" => "string"},
                              "idempotency_key" => %{"type" => "string"},
                              "memory_id" => %{"type" => "string"},
                              "reason" => %{"type" => "string"},
                              "request_id" => %{"type" => "string"}
                            },
                            "required" => ["memory_id", "reason", "idempotency_key"],
                            "type" => "object"
                          }},
                         {"memory::lesson_save",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "correlation_id" => %{"type" => "string"},
                              "context" => %{"type" => "string"},
                              "idempotency_key" => %{"type" => "string"},
                              "project" => %{"type" => "string"},
                              "request_id" => %{"type" => "string"},
                              "rule" => %{"type" => "string"},
                              "session_id" => %{"type" => "string"}
                            },
                            "required" => [
                              "rule",
                              "context",
                              "project",
                              "idempotency_key"
                            ],
                            "type" => "object"
                          }},
                         {"memory::lesson_strengthen",
                          %{
                            "additionalProperties" => false,
                            "properties" => %{
                              "correlation_id" => %{"type" => "string"},
                              "idempotency_key" => %{"type" => "string"},
                              "memory_id" => %{"type" => "string"},
                              "mode" => %{
                                "enum" => [
                                  "explicit_confirmation",
                                  "verified_application",
                                  "independent_evidence"
                                ],
                                "type" => "string"
                              },
                              "request_id" => %{"type" => "string"},
                              "source_event_id" => %{"type" => "string"},
                              "source_observation_id" => %{"type" => "string"},
                              "source_request_id" => %{"type" => "string"},
                              "source_summary_id" => %{"type" => "string"},
                              "source_session_id" => %{"type" => "string"}
                            },
                            "required" => [
                              "memory_id",
                              "mode",
                              "idempotency_key"
                            ],
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
                              "host_id" => %{
                                "description" => "Exact canonical host ID",
                                "type" => "string"
                              },
                              "limit" => %{
                                "default" => 10,
                                "description" => "Maximum tool patterns to return",
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              },
                              "offset" => %{
                                "default" => 0,
                                "description" => "Aggregated tool patterns to skip",
                                "maximum" => 10_000,
                                "minimum" => 0,
                                "type" => "integer"
                              },
                              "project" => %{
                                "description" => "Exact canonical project",
                                "type" => "string"
                              },
                              "session_id" => %{
                                "description" => "Exact canonical session ID",
                                "type" => "string"
                              }
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
                            "additionalProperties" => false,
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "channel_weights" => %{
                                "additionalProperties" => false,
                                "properties" => %{
                                  "fts" => %{"type" => "number"},
                                  "graph" => %{"type" => "number"},
                                  "vector" => %{"type" => "number"}
                                },
                                "type" => "object"
                              },
                              "entity_hints" => %{
                                "items" => %{"type" => "string"},
                                "type" => "array"
                              },
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
                              "host_id" => %{"type" => "string"},
                              "include_working" => %{"default" => false, "type" => "boolean"},
                              "limit" => %{"default" => 10, "type" => "integer"},
                              "project" => %{"type" => "string"},
                              "query" => %{
                                "description" => "Query text",
                                "type" => "string"
                              },
                              "scope" => %{"type" => "string"},
                              "tag" => %{"type" => "string"},
                              "temporal_hints" => %{"type" => "object"},
                              "token_budget" => %{"type" => "integer"}
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
                            "additionalProperties" => false,
                            "properties" => %{
                              "agent_id" => %{"type" => "string"},
                              "content" => %{
                                "description" => "Memory text",
                                "type" => "string"
                              },
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
                              "idempotency_key" => %{"type" => "string"},
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
                            "required" => ["content", "agent_id"],
                            "type" => "object"
                          }},
                         {"memory::sessions",
                          %{
                            "properties" => %{
                              "host_id" => %{
                                "description" => "Exact canonical host ID",
                                "type" => "string"
                              },
                              "limit" => %{
                                "default" => 20,
                                "description" => "Maximum projected sessions to return",
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              },
                              "offset" => %{
                                "default" => 0,
                                "description" => "Projected session rows to skip",
                                "maximum" => 10_000,
                                "minimum" => 0,
                                "type" => "integer"
                              },
                              "project" => %{
                                "description" => "Exact canonical project",
                                "type" => "string"
                              },
                              "session_id" => %{
                                "description" => "Exact canonical session ID",
                                "type" => "string"
                              }
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
                              "event_type" => %{
                                "description" => "Exact canonical event type",
                                "type" => "string"
                              },
                              "file_path" => %{
                                "description" => "Exact projected file path membership",
                                "type" => "string"
                              },
                              "host_id" => %{
                                "description" => "Exact canonical host ID",
                                "type" => "string"
                              },
                              "is_error" => %{
                                "description" => "Filter projected events by error status",
                                "type" => "boolean"
                              },
                              "limit" => %{
                                "default" => 50,
                                "description" => "Maximum projected timeline events to return",
                                "maximum" => 100,
                                "minimum" => 1,
                                "type" => "integer"
                              },
                              "minimum_importance" => %{
                                "description" => "Minimum canonical event importance, inclusive",
                                "maximum" => 2_147_483_647,
                                "minimum" => -2_147_483_648,
                                "type" => "integer"
                              },
                              "occurred_from" => %{
                                "description" => "Earliest canonical occurrence time, inclusive",
                                "format" => "date-time",
                                "type" => "string"
                              },
                              "occurred_to" => %{
                                "description" => "Latest canonical occurrence time, inclusive",
                                "format" => "date-time",
                                "type" => "string"
                              },
                              "offset" => %{
                                "default" => 0,
                                "description" => "Filtered projected timeline events to skip",
                                "maximum" => 10_000,
                                "minimum" => 0,
                                "type" => "integer"
                              },
                              "project" => %{
                                "description" => "Exact canonical project",
                                "type" => "string"
                              },
                              "session_id" => %{
                                "description" => "Exact canonical session ID",
                                "type" => "string"
                              },
                              "tool_name" => %{
                                "description" => "Exact projected tool name",
                                "type" => "string"
                              }
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
    previous_pipeline = :ets.lookup(:backplane_settings, "memory.pipeline.enabled")
    previous_replay = :ets.lookup(:backplane_settings, "memory.replay_enabled")
    previous_import = :ets.lookup(:backplane_settings, "memory.replay_import_enabled")
    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", true})
    :ets.insert(:backplane_settings, {"memory.replay_enabled", true})
    :ets.insert(:backplane_settings, {"memory.replay_import_enabled", true})

    on_exit(fn ->
      case previous do
        [] -> :ets.delete(:backplane_settings, "memory.tools")
        rows -> :ets.insert(:backplane_settings, rows)
      end

      case previous_import do
        [] -> :ets.delete(:backplane_settings, "memory.replay_import_enabled")
        rows -> :ets.insert(:backplane_settings, rows)
      end

      case previous_replay do
        [] -> :ets.delete(:backplane_settings, "memory.replay_enabled")
        rows -> :ets.insert(:backplane_settings, rows)
      end

      case previous_pipeline do
        [] -> :ets.delete(:backplane_settings, "memory.pipeline.enabled")
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
    test "returns the exact 41 core names and input schemas" do
      set_tool_mode("core")
      tools = Service.tools()
      names = Enum.map(tools, & &1.name)

      assert length(tools) == 41
      assert length(Enum.uniq(names)) == 41
      assert contracts(tools) == @core_tool_contracts
      assert map_size(@core_tool_contracts) == 41
    end

    test "all returned tools have required fields" do
      tools = Service.tools()

      for tool <- tools do
        assert is_binary(tool.name), "name must be a string: #{inspect(tool)}"
        assert is_binary(tool.description), "description must be a string for #{tool.name}"
        assert is_map(tool.input_schema), "input_schema must be a map for #{tool.name}"

        assert is_function(tool.handler, 1) or is_function(tool.handler, 2),
               "handler must be arity-1 or arity-2 fun for #{tool.name}"
      end
    end

    test "consolidate and replay import remain extended-only" do
      set_tool_mode("core")
      refute Enum.any?(Service.tools(), &(&1.name == "memory::consolidate"))
      refute Enum.any?(Service.tools(), &(&1.name == "memory::replay_import"))

      set_tool_mode("all")
      assert Enum.any?(Service.tools(), &(&1.name == "memory::consolidate"))
      assert Enum.any?(Service.tools(), &(&1.name == "memory::replay_import"))
    end
  end

  describe "tools/0 — extended tools (memory.tools = 'all')" do
    test "returns the exact 55 full names and input schemas" do
      set_tool_mode("all")
      tools = Service.tools()
      names = Enum.map(tools, & &1.name)

      assert length(tools) == 55
      assert length(Enum.uniq(names)) == 55
      assert contracts(tools) == @full_tool_contracts
      assert map_size(@full_tool_contracts) == 55
    end
  end

  test "memory::action_create records each supplied provenance origin" do
    ids = %{
      observation: Ecto.UUID.generate(),
      memory: Ecto.UUID.generate(),
      lesson: Ecto.UUID.generate(),
      crystal: Ecto.UUID.generate()
    }

    assert {:ok, %{id: action_id}} =
             Service.trusted_call("memory::action_create", %{
               "title" => "Traceable tool action",
               "source_observation_ids" => [ids.observation],
               "source_memory_ids" => [ids.memory],
               "source_session_ids" => ["session-a"],
               "source_lesson_ids" => [ids.lesson],
               "source_crystal_ids" => [ids.crystal]
             })

    action = repo().get!(Action, action_id)
    assert action.source_observation_ids == [ids.observation]
    assert action.source_memory_ids == [ids.memory]
    assert action.source_session_ids == ["session-a"]
    assert action.source_lesson_ids == [ids.lesson]
    assert action.source_crystal_ids == [ids.crystal]
  end

  test "memory::export audits the exact authenticated partition without exported content" do
    set_tool_mode("core")

    host =
      repo().insert!(
        Host.changeset(%Host{}, %{
          name: "export-host-#{System.unique_integer([:positive])}",
          memory_scope: "scope:export"
        })
      )

    client_id = "host:#{host.id}"

    assert {:ok, memory} =
             Memories.remember("export secret",
               host_id: host.id,
               client_id: client_id,
               scope: host.memory_scope,
               namespace: "private",
               agent_id: "export-agent"
             )

    auth = %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      scopes: ["memory.replay"],
      principal_metadata: %{"memory_partition_id" => client_id}
    }

    assert {:ok, %{count: 1}} = Service.call("memory::export", %{}, auth)

    partition = %{
      host_id: host.id,
      client_id: client_id,
      scope: host.memory_scope,
      namespace: "private"
    }

    assert [%{target_ids: [memory_id], metadata: metadata}] =
             Audit.list(partition, operation: "memory.export")

    assert memory_id == memory.id
    assert metadata["result"] == "exported"
    assert metadata["memory_count"] == 1
    assert metadata["correlation_ids"] == [metadata["request_id"]]
    refute inspect(metadata) =~ "export secret"
  end

  # ──────────────────────────────────────────────
  # handle_governance_delete/1
  # ──────────────────────────────────────────────

  describe "handle_governance_delete/1" do
    test "soft-deletes a memory and writes an audit entry" do
      {:ok, mem} =
        Memories.remember("temporary fact",
          agent_id: "gov_agent",
          host_id: "gov_host",
          client_id: "gov_client",
          scope: "gov_scope",
          namespace: "private"
        )

      assert {:ok, result} =
               Service.trusted_call(
                 "memory::governance_delete",
                 Map.merge(memory_partition(mem), %{
                   "memory_id" => mem.id,
                   "actor" => "admin",
                   "reason" => "test cleanup"
                 })
               )

      assert result.status == "soft_deleted"
      assert result.memory_id == mem.id
      assert result.actor == "system"

      # Memory should be soft-deleted
      assert {:error, :not_found} = Memories.trusted_get(mem.id)

      # Audit entry should exist
      entries = Audit.list(operation: "governance_delete")

      assert Enum.any?(entries, fn e ->
               e.target_ids["memory_id"] == mem.id and e.actor == "system"
             end)
    end

    test "governance audit failure rolls back tombstone and both audit writes" do
      {:ok, mem} =
        Memories.remember("atomic governance",
          agent_id: "gov_agent",
          host_id: "gov_host",
          client_id: "gov_client",
          scope: "gov_scope",
          namespace: "private"
        )

      repo().query!("""
      CREATE FUNCTION bpm_test_fail_governance_audit() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.operation = 'governance_delete' THEN
          RAISE EXCEPTION 'injected governance audit failure' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
      END; $$
      """)

      repo().query!("""
      CREATE TRIGGER bpm_test_fail_governance_audit
      BEFORE INSERT ON memory_audit_log
      FOR EACH ROW EXECUTE FUNCTION bpm_test_fail_governance_audit()
      """)

      assert {:error, "governance audit failed"} =
               Service.trusted_call(
                 "memory::governance_delete",
                 Map.merge(memory_partition(mem), %{
                   "memory_id" => mem.id,
                   "actor" => "spoofed-admin",
                   "reason" => "injected failure"
                 })
               )

      assert {:ok, %{lifecycle_state: "active", deleted_at: nil}} = Memories.trusted_get(mem.id)

      refute Enum.any?(Audit.list_for_target(mem.id), fn entry ->
               entry.operation in ["forget", "governance_delete"]
             end)
    end

    test "returns error for unknown memory_id" do
      assert {:error, "memory not found"} =
               Service.trusted_call("memory::governance_delete", %{
                 "memory_id" => Ecto.UUID.generate(),
                 "actor" => "admin"
               })
    end

    test "hard delete refuses retained provenance and audits the denied attempt" do
      previous = Backplane.Settings.get("memory.hard_delete_enabled")
      :ok = Backplane.Settings.set("memory.hard_delete_enabled", "true")
      on_exit(fn -> Backplane.Settings.set("memory.hard_delete_enabled", previous) end)

      {:ok, mem} =
        Memories.remember("governance retained", agent_id: "gov_agent", host_id: "gov_host")

      assert {:error, "memory provenance retained"} =
               Service.trusted_call("memory::governance_delete", %{
                 "memory_id" => mem.id,
                 "actor" => "admin",
                 "reason" => "must retain provenance"
               })

      assert {:ok, ^mem} = Memories.trusted_get(mem.id)

      refute Enum.any?(Audit.list(operation: "governance_delete"), fn entry ->
               entry.target_ids["memory_id"] == mem.id
             end)

      assert [%{metadata: metadata}] =
               Audit.list_for_target(mem.id)
               |> Enum.filter(&(&1.operation == "hard_delete"))

      assert metadata["result"] == "denied"
      assert metadata["reason"] == "provenance_retained"
      assert metadata["host_id"] == mem.host_id
      assert metadata["client_id"] == mem.client_id
      assert metadata["scope"] == mem.scope
      assert metadata["namespace"] == mem.namespace
      assert {:ok, _request_id} = Ecto.UUID.cast(metadata["request_id"])
    end

    test "returns error when memory_id is missing" do
      assert {:error, _} =
               Service.trusted_call("memory::governance_delete", %{"actor" => "admin"})
    end
  end

  # ──────────────────────────────────────────────
  # resources/0 and prompts/0
  # ──────────────────────────────────────────────

  describe "authenticated resources" do
    setup do
      set_tool_mode("all")

      {:ok, host} =
        repo().insert(
          Host.changeset(%Host{}, %{
            name: "resource-host-#{System.unique_integer([:positive])}",
            memory_scope: "scope:resources"
          })
        )

      auth = %{
        kind: :client_token,
        client_id: Ecto.UUID.generate(),
        subject: "resource-test",
        scopes: ["memory.read", "memory.write", "memory.admin"],
        principal_metadata: %{"memory_partition_id" => "host:#{host.id}"}
      }

      %{auth: auth, host: host}
    end

    test "legacy resource helpers fail closed" do
      assert Service.resources() == []
      assert {:error, :unauthorized} = Service.read_resource("memory://status")
    end

    test "returns authorized resource definitions with required fields", %{auth: auth} do
      resources = Service.resources(auth)
      assert length(resources) == 8
      assert Enum.any?(resources, &(&1.uri == "memory://lessons/top"))

      for r <- resources do
        assert is_binary(r.uri)
        assert is_binary(r.name)
        assert is_binary(r.description)
        assert is_binary(r.mime_type)
      end
    end

    test "returns only the two authorized dynamic resource templates", %{auth: auth} do
      assert [] == Service.resource_templates()

      assert [recall_trace, session_handoff] =
               Service.resource_templates(auth)
               |> Enum.sort_by(& &1.uri_template)

      assert recall_trace.uri_template == "memory://recall/{id}/trace"
      assert session_handoff.uri_template == "memory://session/{id}/handoff"

      assert [] == Service.resource_templates(%{auth | scopes: ["memory.write"]})
    end

    test "memory://status returns JSON with status ok", %{auth: auth} do
      assert {:ok, json} = Service.read_resource("memory://status", auth)
      assert %{"status" => "ok"} = Jason.decode!(json)
    end

    test "memory://lessons/top returns bounded exact-partition active lessons with provenance", %{
      auth: auth
    } do
      assert {:ok, %{memory_id: memory_id}} =
               Service.call(
                 "memory::lesson_save",
                 %{
                   "rule" => "Verify the exact production artifact",
                   "context" => "resource contract",
                   "project" => "backplane",
                   "session_id" => "resource-session",
                   "idempotency_key" => "resource-top-lesson"
                 },
                 auth
               )

      assert {:ok, json} = Service.read_resource("memory://lessons/top", auth)
      assert %{"results" => [lesson]} = Jason.decode!(json)
      assert lesson["memory_id"] == memory_id
      assert lesson["kind"] == "lesson"
      assert lesson["status"] == "active"
      assert lesson["rule"] == "Verify the exact production artifact"
      assert lesson["evidence_ids"] != []
      assert lesson["source_refs"] != []
    end

    test "unknown URI returns {:error, :not_found}", %{auth: auth} do
      assert {:error, :not_found} = Service.read_resource("memory://does_not_exist", auth)
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

    test "get_prompt/2 fails closed for session_handoff without trusted auth" do
      assert {:error, :unauthorized} =
               Service.get_prompt("session_handoff", %{"session_id" => "abc"})
    end

    test "get_prompt/2 fails closed before revealing whether a prompt exists" do
      assert {:error, :unauthorized} = Service.get_prompt("nonexistent", %{})
    end
  end

  defp memory_partition(memory) do
    %{
      "host_id" => memory.host_id,
      "client_id" => memory.client_id,
      "scope" => memory.scope,
      "namespace" => memory.namespace
    }
  end
end
