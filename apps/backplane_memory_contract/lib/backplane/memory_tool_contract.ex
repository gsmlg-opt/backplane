defmodule Backplane.MemoryToolContract do
  @moduledoc "Shared process-free contract for the public Memory MCP tools."

  @core_permissions %{
    "memory::search" => "memory.read",
    "memory::get" => "memory.read",
    "memory::recent" => "memory.read",
    "memory::remember" => "memory.write",
    "memory::forget" => "memory.write"
  }
  @core_tools ~w(memory::search memory::get memory::recent memory::remember memory::forget)

  @kinds ~w(fact procedure worklog note)
  @subject_pattern "^[^:\\s]+:.+$"

  @schemas %{
    "memory::search" => %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "minLength" => 1},
        "host" => %{"type" => "string"},
        "agent" => %{"type" => "string"},
        "kind" => %{"type" => "string", "enum" => @kinds},
        "subject" => %{
          "type" => "string",
          "pattern" => @subject_pattern,
          "description" => "Subject as type:key"
        },
        "since" => %{"type" => "string", "description" => "ISO 8601 timestamp"},
        "until" => %{"type" => "string", "description" => "ISO 8601 timestamp"},
        "include_inactive" => %{"type" => "boolean", "default" => false},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10},
        "token_budget" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["query"]
    },
    "memory::get" => %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "string"}},
      "required" => ["id"]
    },
    "memory::recent" => %{
      "type" => "object",
      "properties" => %{
        "host" => %{"type" => "string"},
        "agent" => %{"type" => "string"},
        "since" => %{"type" => "string", "description" => "ISO 8601 timestamp"},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 20}
      }
    },
    "memory::remember" => %{
      "type" => "object",
      "properties" => %{
        "content" => %{"type" => "string", "minLength" => 1},
        "kind" => %{"type" => "string", "enum" => @kinds, "default" => "note"},
        "title" => %{"type" => "string"},
        "subjects" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{"type" => %{"type" => "string"}, "key" => %{"type" => "string"}},
            "required" => ["type", "key"]
          }
        },
        "property" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "writer" => %{"type" => "string", "enum" => ["agent", "user"], "default" => "agent"},
        "session_id" => %{"type" => "string"},
        "host" => %{"type" => "string"},
        "agent" => %{"type" => "string"},
        "integration" => %{"type" => "string"},
        "request_key" => %{"type" => "string"}
      },
      "required" => ["content"]
    },
    "memory::forget" => %{
      "type" => "object",
      "properties" => %{
        "id" => %{"type" => "string"},
        "reason" => %{"type" => "string", "minLength" => 1}
      },
      "required" => ["id", "reason"]
    }
  }

  @doc "Names of the five public memory tools."
  @spec tools() :: [String.t()]
  def tools, do: @core_tools

  @doc "Permission classes granted to memory clients."
  @spec permissions() :: [String.t()]
  def permissions, do: ["memory.read", "memory.write"]

  @spec permission_for(String.t()) :: String.t() | nil
  def permission_for(name), do: Map.get(@core_permissions, name)

  @doc "Input JSON schemas for the five public tools, keyed by tool name."
  @spec schemas() :: %{String.t() => map()}
  def schemas, do: @schemas
end
