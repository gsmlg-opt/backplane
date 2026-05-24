defmodule BackplaneMemory.Service do
  @moduledoc "Managed MCP service exposing memory::* tools."

  @behaviour Backplane.Services.ManagedService

  alias BackplaneMemory.Memories.Search
  alias BackplaneMemory.Memory

  @impl true
  def prefix, do: "memory"

  @impl true
  def enabled?, do: Backplane.Settings.get("services.memory.enabled") == true

  @impl true
  def tools do
    [
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
            "scope" => %{"type" => "string", "description" => "Scope key", "default" => "global"},
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
      }
    ]
  end

  def handle_remember(%{"content" => content} = args) when is_binary(content) do
    opts =
      [
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
        {:ok, %{id: mem.id, scope: mem.scope, memory_type: mem.memory_type}}

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

    case Search.recall(query, opts) do
      {:ok, results} -> {:ok, %{results: results}}
      {:error, reason} -> {:error, inspect(reason)}
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
