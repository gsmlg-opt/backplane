defmodule Backplane.Tools.Skill do
  @moduledoc """
  Native MCP tools for the Skills engine.
  Registers: skill::search, skill::load, skill::list, skill::create, skill::update
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Skills.{Deps, Registry, Search, Versions}
  alias Backplane.Skills.Sources.Database
  alias Backplane.Utils

  @impl true
  def tools do
    [
      %{
        name: "skill::search",
        description: "Search for available skills by keyword, tag, or tool requirement",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search keywords"},
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter by tags"
            },
            "tools" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter by required tools"
            },
            "limit" => %{"type" => "integer", "description" => "Max results (default 10)"}
          },
          "required" => ["query"]
        },
        module: __MODULE__,
        handler: :search
      },
      %{
        name: "skill::load",
        description:
          "Load a skill's full content for injection into agent context. With resolve_deps (default true), also loads transitive dependencies in topological order.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "skill_id" => %{"type" => "string", "description" => "Skill ID from skill::search"},
            "resolve_deps" => %{
              "type" => "boolean",
              "description" => "Resolve and load dependency chain (default true)"
            },
            "version" => %{
              "type" => "integer",
              "description" => "Load a specific version (DB skills only)"
            }
          },
          "required" => ["skill_id"]
        },
        module: __MODULE__,
        handler: :load
      },
      %{
        name: "skill::list",
        description: "List all available skills with metadata (no content)",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "source" => %{"type" => "string", "description" => "Filter by source: git, local, db"},
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter by tags"
            }
          }
        },
        module: __MODULE__,
        handler: :list
      },
      %{
        name: "skill::create",
        description: "Create a new database-sourced skill",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "content" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "tools" => %{"type" => "array", "items" => %{"type" => "string"}},
            "model" => %{"type" => "string"}
          },
          "required" => ["name", "description", "content"]
        },
        module: __MODULE__,
        handler: :create
      },
      %{
        name: "skill::versions",
        description: "List version history for a DB-sourced skill",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "skill_id" => %{"type" => "string", "description" => "Skill ID"},
            "limit" => %{
              "type" => "integer",
              "description" => "Max versions to return (default 10)"
            }
          },
          "required" => ["skill_id"]
        },
        module: __MODULE__,
        handler: :versions
      },
      %{
        name: "skill::update",
        description: "Update a database-sourced skill",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "skill_id" => %{"type" => "string"},
            "content" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
            "enabled" => %{"type" => "boolean"}
          },
          "required" => ["skill_id"]
        },
        module: __MODULE__,
        handler: :update
      }
    ]
  end

  @impl true
  @spec call(map()) :: {:ok, term()} | {:error, term()}
  def call(%{"_handler" => "search"} = args) do
    opts =
      []
      |> maybe_add(:tags, args["tags"])
      |> maybe_add(:tools, args["tools"])
      |> maybe_add(:limit, args["limit"])

    results = Search.query(args["query"], opts)
    {:ok, results}
  end

  def call(%{"_handler" => "load"} = args) do
    skill_id = args["skill_id"]
    version = args["version"]
    resolve_deps? = Map.get(args, "resolve_deps", true)

    cond do
      # Load specific version (DB skills only)
      version ->
        load_version(skill_id, version)

      # Load with dependency resolution
      resolve_deps? ->
        load_with_deps(skill_id)

      # Load single skill
      true ->
        load_single(skill_id)
    end
  end

  def call(%{"_handler" => "list"} = args) do
    opts =
      []
      |> maybe_add(:source, args["source"])
      |> maybe_add(:tags, args["tags"])

    skills =
      Registry.list(opts)
      |> Enum.map(fn s ->
        %{
          id: s.id,
          name: s.name,
          description: s.description,
          tags: s.tags,
          version: s.version,
          source: s.source,
          enabled: Map.get(s, :enabled, true)
        }
      end)

    {:ok, skills}
  end

  def call(%{"_handler" => "create"} = args) do
    attrs = %{
      name: args["name"],
      description: args["description"],
      content: args["content"],
      tags: args["tags"] || [],
      tools: args["tools"] || [],
      model: args["model"]
    }

    case Database.create(attrs) do
      {:ok, skill} ->
        Registry.refresh()
        {:ok, %{id: skill.id, name: skill.name, source: skill.source}}

      {:error, changeset} ->
        {:error, "Failed to create skill: #{inspect(changeset.errors)}"}
    end
  end

  def call(%{"_handler" => "update"} = args) do
    skill_id = args["skill_id"]

    allowed_keys = %{
      "content" => :content,
      "description" => :description,
      "tags" => :tags,
      "enabled" => :enabled
    }

    attrs =
      args
      |> Map.take(Map.keys(allowed_keys))
      |> Map.new(fn {k, v} -> {Map.fetch!(allowed_keys, k), v} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    # Snapshot current version before update
    case Backplane.Repo.get(Backplane.Skills.Skill, skill_id) do
      nil ->
        :skip

      skill ->
        if skill.source == "db" do
          Versions.snapshot(skill, author: args["_client_name"] || "system")
        end
    end

    case Database.update(skill_id, attrs) do
      {:ok, skill} ->
        Registry.refresh()
        {:ok, %{id: skill.id, name: skill.name}}

      {:error, :not_found} ->
        {:error, "Skill not found: #{skill_id}"}

      {:error, :readonly_source} ->
        {:error, "Cannot update non-database skill: #{skill_id}"}

      {:error, changeset} ->
        {:error, "Failed to update: #{inspect(changeset.errors)}"}
    end
  end

  def call(%{"_handler" => "versions"} = args) do
    skill_id = args["skill_id"]
    limit = args["limit"] || 10

    # Check if skill is DB-sourced
    case Registry.fetch(skill_id) do
      {:ok, %{source: source}} when source != "db" ->
        {:ok,
         %{
           versions: [],
           message: "Version history not available for #{source}-sourced skills. Use git log."
         }}

      {:ok, _} ->
        versions =
          Versions.list(skill_id, limit: limit)
          |> Enum.map(fn v ->
            %{
              version: v.version,
              content_hash: v.content_hash,
              author: v.author,
              change_summary: v.change_summary,
              inserted_at: v.inserted_at && DateTime.to_iso8601(v.inserted_at)
            }
          end)

        {:ok, %{versions: versions}}

      {:error, :not_found} ->
        {:error, "Skill not found: #{skill_id}"}
    end
  end

  # Default handler — route based on tool name
  def call(args) do
    {:error, "Unknown skill tool handler: #{inspect(args)}"}
  end

  defp load_single(skill_id) do
    case Registry.fetch(skill_id) do
      {:ok, entry} ->
        {:ok, format_skill_for_load(entry)}

      {:error, :not_found} ->
        {:error, "Skill not found: #{skill_id}"}
    end
  end

  defp load_with_deps(skill_id) do
    case Deps.resolve(skill_id) do
      {:ok, skills} ->
        loaded = Enum.map(skills, &format_skill_for_load/1)
        {:ok, loaded}

      {:ok, skills, warnings} ->
        loaded = Enum.map(skills, &format_skill_for_load/1)
        {:ok, %{skills: loaded, warnings: warnings}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_version(skill_id, version) do
    # Check if skill is DB-sourced
    case Registry.fetch(skill_id) do
      {:ok, %{source: source}} when source != "db" ->
        {:error, "Version history not available for #{source}-sourced skills. Use git log."}

      {:ok, entry} ->
        case Versions.get(skill_id, version) do
          {:ok, sv} ->
            {:ok,
             %{
               id: entry.id,
               name: entry.name,
               content: sv.content,
               version: sv.version,
               tools: entry.tools,
               model: entry.model
             }}

          {:error, :not_found} ->
            {:error, "Version #{version} not found for skill #{skill_id}"}
        end

      {:error, :not_found} ->
        {:error, "Skill not found: #{skill_id}"}
    end
  end

  defp format_skill_for_load(entry) do
    %{
      id: entry.id,
      name: entry.name,
      content: entry.content,
      tools: entry[:tools],
      model: entry[:model]
    }
  end

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
