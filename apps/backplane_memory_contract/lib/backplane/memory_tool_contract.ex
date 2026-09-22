defmodule Backplane.MemoryToolContract do
  @moduledoc "Shared process-free contract for the public Memory MCP tools."

  @canonical_overlap ~w(
    memory::facet_query
    memory::facet_tag
    memory::forget
    memory::list
    memory::recall
    memory::remember
    memory::stats
  )

  @device_local ~w(
    memory::slot_list
    memory::slot_read
    memory::slot_write
  )

  @server_only ~w(
    memory::access_log
    memory::activity_summary
    memory::action_create
    memory::action_update
    memory::apply
    memory::audit
    memory::compress_file
    memory::consolidate
    memory::crystal_get
    memory::crystal_list
    memory::crystal_search
    memory::crystallize
    memory::diagnose
    memory::enrich
    memory::expand_query
    memory::export
    memory::file_history
    memory::frontier
    memory::governance_delete
    memory::graph_query
    memory::graph_stats
    memory::heal
    memory::lease
    memory::lesson_archive
    memory::lesson_promote
    memory::lesson_recall
    memory::lesson_save
    memory::lesson_strengthen
    memory::next
    memory::patterns
    memory::profile
    memory::profile_refresh
    memory::recall_explain
    memory::relations
    memory::replay_import
    memory::replay_load
    memory::replay_sessions
    memory::sessions
    memory::signal_read
    memory::signal_send
    memory::smart_search
    memory::team_feed
    memory::team_share
    memory::timeline
    memory::verify
  )

  @read_tools ~w(
    memory::access_log memory::activity_summary memory::crystal_get memory::crystal_list
    memory::crystal_search memory::expand_query memory::facet_query memory::file_history
    memory::graph_query memory::graph_stats memory::list memory::lesson_recall memory::patterns
    memory::profile memory::recall memory::recall_explain memory::relations memory::sessions
    memory::slot_list memory::slot_read memory::smart_search memory::stats memory::team_feed
    memory::timeline memory::verify
  )
  @write_tools ~w(
    memory::apply memory::compress_file memory::consolidate memory::enrich memory::facet_tag
    memory::forget memory::lesson_save memory::lesson_strengthen memory::profile_refresh
    memory::remember memory::slot_write memory::team_share
  )
  @coordinate_tools ~w(
    memory::action_create memory::action_update memory::frontier memory::lease memory::next
    memory::signal_read memory::signal_send
  )
  @replay_tools ~w(memory::export memory::replay_load memory::replay_sessions)
  @admin_tools ~w(
    memory::audit memory::crystallize memory::diagnose memory::governance_delete memory::heal
    memory::lesson_archive memory::lesson_promote memory::replay_import
  )

  @permissions Enum.reduce(
                 [
                   {"memory.read", @read_tools},
                   {"memory.write", @write_tools},
                   {"memory.coordinate", @coordinate_tools},
                   {"memory.replay", @replay_tools},
                   {"memory.admin", @admin_tools}
                 ],
                 %{},
                 fn {permission, names}, permissions ->
                   Enum.reduce(names, permissions, &Map.put(&2, &1, permission))
                 end
               )

  @type route_class :: :canonical_overlap | :server_only | :device_local | :unknown

  @spec canonical_overlap_names() :: [String.t()]
  def canonical_overlap_names, do: @canonical_overlap

  @spec server_only_names() :: [String.t()]
  def server_only_names, do: @server_only

  @spec device_local_names() :: [String.t()]
  def device_local_names, do: @device_local

  @spec route_class(String.t()) :: route_class()
  def route_class(name) when name in @canonical_overlap, do: :canonical_overlap
  def route_class(name) when name in @server_only, do: :server_only
  def route_class(name) when name in @device_local, do: :device_local
  def route_class(_name), do: :unknown

  @spec permissions() :: %{String.t() => String.t()}
  def permissions, do: @permissions

  @spec permission!(String.t()) :: String.t()
  def permission!(name), do: Map.fetch!(@permissions, name)

  @spec permission(String.t()) :: {:ok, String.t()} | :error
  def permission(name), do: Map.fetch(@permissions, name)

  @spec metadata(String.t()) :: {:ok, map()} | :error
  def metadata(name) do
    with {:ok, permission} <- permission(name),
         class when class != :unknown <- route_class(name) do
      {:ok, %{"backplane" => Map.merge(%{"permission" => permission}, route_metadata(class))}}
    else
      _ -> :error
    end
  end

  defp route_metadata(:canonical_overlap),
    do: %{
      "authority" => "canonical",
      "consistency" => "canonical_or_bounded_stale",
      "availability" => "online_or_offline"
    }

  defp route_metadata(:server_only),
    do: %{"authority" => "canonical", "consistency" => "canonical", "availability" => "online"}

  defp route_metadata(:device_local),
    do: %{
      "authority" => "device_local",
      "consistency" => "device_local",
      "availability" => "online_or_offline"
    }

  @facet_tag_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "properties" => %{"dimension" => %{"type" => "string"}, "value" => %{"type" => "string"}},
      "required" => ["dimension", "value"]
    }
  }

  @facet_query_schema %{
    "type" => "array",
    "items" => %{
      "type" => "object",
      "properties" => %{"dimension" => %{"type" => "string"}, "value" => %{"type" => "string"}}
    }
  }

  @tools %{
    "memory::facet_query" => %{
      name: "memory::facet_query",
      description: "Query memories by facet filter (AND across dimensions).",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "facets" => @facet_query_schema,
          "limit" => %{"type" => "integer", "default" => 20}
        },
        "required" => ["facets"]
      }
    },
    "memory::facet_tag" => %{
      name: "memory::facet_tag",
      description: "Tag an existing memory with dimension:value facets.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"memory_id" => %{"type" => "string"}, "facets" => @facet_tag_schema},
        "required" => ["memory_id", "facets"]
      }
    },
    "memory::forget" => %{
      name: "memory::forget",
      description: "Soft-delete a memory by id.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"]
      }
    },
    "memory::list" => %{
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
      }
    },
    "memory::recall" => %{
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
          "facets" => @facet_tag_schema
        },
        "required" => ["query"],
        "additionalProperties" => false
      }
    },
    "memory::remember" => %{
      name: "memory::remember",
      description: "Persist a memory entry with durable request idempotency.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "content" => %{"type" => "string", "description" => "Memory text"},
          "facets" => @facet_tag_schema,
          "type" => %{
            "type" => "string",
            "description" => "working | episodic | semantic | procedural",
            "default" => "semantic"
          },
          "scope" => %{"type" => "string", "description" => "Scope key", "default" => "global"},
          "agent_id" => %{"type" => "string"},
          "idempotency_key" => %{"type" => "string"},
          "session_id" => %{"type" => "string"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "metadata" => %{"type" => "object"}
        },
        "required" => ["content", "agent_id"],
        "additionalProperties" => false
      }
    },
    "memory::stats" => %{
      name: "memory::stats",
      description: "Return counts grouped by memory_type.",
      input_schema: %{"type" => "object", "properties" => %{}}
    },
    "memory::slot_list" => %{
      name: "memory::slot_list",
      description: "List all memory slots and their content.",
      input_schema: %{"type" => "object", "properties" => %{}}
    },
    "memory::slot_read" => %{
      name: "memory::slot_read",
      description: "Read a named memory slot.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }
    },
    "memory::slot_write" => %{
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
      }
    }
  }

  @spec tool!(String.t()) :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          meta: map()
        }
  def tool!(name) do
    %{name: name, description: description, input_schema: input_schema} = Map.fetch!(@tools, name)
    {:ok, meta} = metadata(name)
    %{name: name, description: description, input_schema: input_schema, meta: meta}
  end

  @spec tool(String.t()) :: {:ok, map()} | :error
  def tool(name) do
    if Map.has_key?(@tools, name), do: {:ok, tool!(name)}, else: :error
  end
end
