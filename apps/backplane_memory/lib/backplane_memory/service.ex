defmodule BackplaneMemory.Service do
  @moduledoc "Managed MCP service exposing memory::* tools."

  @behaviour Backplane.Services.ManagedService

  alias BackplaneMemory.Memories.{Profiles, Search}
  alias BackplaneMemory.Memory

  @impl true
  def prefix, do: "memory"

  @impl true
  def enabled?, do: Backplane.Settings.get("services.memory.enabled") == true

  @impl true
  def tools do
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
    import Ecto.Query
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
