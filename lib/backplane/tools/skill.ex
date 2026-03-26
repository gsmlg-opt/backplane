defmodule Backplane.Tools.Skill do
  @moduledoc """
  Native MCP tools for the Skills engine.
  Registers: skill::search, skill::load, skill::list, skill::create, skill::update
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Skills.{Registry, Search}
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
        description: "Load a skill's full content for injection into agent context",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "skill_id" => %{"type" => "string", "description" => "Skill ID from skill::search"}
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
    case Registry.fetch(args["skill_id"]) do
      {:ok, entry} ->
        {:ok,
         %{
           id: entry.id,
           name: entry.name,
           content: entry.content,
           tools: entry.tools,
           model: entry.model
         }}

      {:error, :not_found} ->
        {:error, "Skill not found: #{args["skill_id"]}"}
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

  # Default handler — route based on tool name
  def call(args) do
    {:error, "Unknown skill tool handler: #{inspect(args)}"}
  end

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
