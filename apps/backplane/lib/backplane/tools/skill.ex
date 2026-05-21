defmodule Backplane.Tools.Skill do
  @moduledoc """
  Native MCP tools for the Skills engine.
  Registers v1 Skills Hub tools plus legacy create/update helpers.
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Skills
  alias Backplane.Skills.{Archive, Registry, Search}
  alias Backplane.Skills.Sources.Database
  alias Backplane.Utils

  @impl true
  def tools do
    [
      %{
        name: "skill::search",
        description: "Search for available skills by keyword and tags",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search keywords"},
            "tags" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Filter by tags"
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
          "Load a skill archive's SKILL.md, meta.json, file list, and archive metadata.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "slug" => %{"type" => "string", "description" => "Skill slug"},
            "skill_id" => %{"type" => "string", "description" => "Legacy skill ID"}
          }
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
        name: "skill::download",
        description: "Return the archive download URL, hash, size, and metadata for a skill",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "slug" => %{"type" => "string", "description" => "Skill slug"},
            "skill_id" => %{"type" => "string", "description" => "Legacy skill ID"}
          }
        },
        module: __MODULE__,
        handler: :download
      },
      %{
        name: "skill::publish",
        description: "Publish a base64-encoded .tar.gz skill archive",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "archive_base64" => %{"type" => "string", "description" => "Base64 .tar.gz archive"},
            "filename" => %{"type" => "string", "description" => "Original archive filename"}
          },
          "required" => ["archive_base64"]
        },
        module: __MODULE__,
        handler: :publish
      },
      %{
        name: "skill::create",
        description: "Legacy: create a database-sourced string skill",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "description" => %{"type" => "string"},
            "content" => %{"type" => "string"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["name", "description", "content"]
        },
        module: __MODULE__,
        handler: :create
      },
      %{
        name: "skill::update",
        description: "Legacy: update a database-sourced string skill",
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
      |> maybe_add(:limit, args["limit"])

    results = Search.query(args["query"], opts)
    {:ok, results}
  end

  def call(%{"_handler" => "load"} = args) do
    load_skill(args["slug"] || args["skill_id"])
  end

  def call(%{"_handler" => "download"} = args) do
    download_skill(args["slug"] || args["skill_id"])
  end

  def call(%{"_handler" => "publish"} = args) do
    publish_skill(args)
  end

  def call(%{"_handler" => "list"} = args) do
    opts =
      []
      |> maybe_add(:tags, args["tags"])

    skills =
      Registry.list(opts)
      |> Enum.map(&metadata_from_map/1)

    {:ok, skills}
  end

  def call(%{"_handler" => "create"} = args) do
    attrs = %{
      name: args["name"],
      description: args["description"],
      content: args["content"],
      tags: args["tags"] || []
    }

    case Database.create(attrs) do
      {:ok, skill} ->
        Registry.refresh()
        {:ok, %{id: skill.id, name: skill.name}}

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

  defp load_skill(nil), do: {:error, "Skill slug is required"}

  defp load_skill(id_or_slug) do
    case Skills.get(id_or_slug) do
      {:ok, skill} ->
        with {:ok, result} <- format_skill_for_load(skill) do
          audit_skill_load(skill)
          {:ok, result}
        end

      {:error, :not_found} ->
        {:error, "Skill not found: #{id_or_slug}"}
    end
  end

  defp download_skill(nil), do: {:error, "Skill slug is required"}

  defp download_skill(id_or_slug) do
    case Skills.get(id_or_slug) do
      {:ok, skill} when is_binary(skill.archive_ref) ->
        metadata = metadata_from_skill(skill)

        {:ok,
         Map.merge(metadata, %{
           url: "/api/skills/#{URI.encode(skill.slug)}/archive",
           hash: skill.content_hash,
           metadata: metadata
         })}

      {:ok, _skill} ->
        {:error, "Skill does not have a downloadable archive: #{id_or_slug}"}

      {:error, :not_found} ->
        {:error, "Skill not found: #{id_or_slug}"}
    end
  end

  defp publish_skill(args) do
    with encoded when is_binary(encoded) <- args["archive_base64"] || args["archive"],
         {:ok, archive} <- Base.decode64(encoded),
         {:ok, skill} <- Skills.ingest_archive(archive, filename: args["filename"]) do
      {:ok, metadata_from_skill(skill)}
    else
      nil -> {:error, "archive_base64 is required"}
      :error -> {:error, "archive_base64 is not valid base64"}
      {:error, reason} -> {:error, "Failed to publish skill: #{inspect(reason)}"}
    end
  end

  defp format_skill_for_load(skill) do
    if skill.archive_ref do
      with {:ok, _skill, stream} <- Skills.archive_stream(skill.slug),
           archive <- Enum.into(stream, ""),
           {:ok, info} <- Archive.inspect(archive) do
        metadata = metadata_from_skill(skill)

        {:ok,
         Map.merge(metadata, %{
           skill_md: info.skill_md,
           meta_json: Jason.encode!(info.meta),
           meta: info.meta,
           files: info.files,
           archive: %{
             ref: skill.archive_ref,
             hash: skill.content_hash,
             size_bytes: skill.size_bytes
           }
         })}
      end
    else
      {:ok,
       skill
       |> metadata_from_skill()
       |> Map.merge(%{
         skill_md: skill.content,
         meta_json: Jason.encode!(skill.meta || %{}),
         meta: skill.meta || %{},
         files: [],
         archive: nil
       })}
    end
  end

  defp metadata_from_skill(skill) do
    %{
      id: skill.id,
      slug: skill.slug,
      name: skill.name,
      description: skill.description,
      tags: skill.tags,
      version: skill.version,
      license: skill.license,
      homepage: skill.homepage,
      author: skill.author,
      content_hash: skill.content_hash,
      archive_ref: skill.archive_ref,
      size_bytes: skill.size_bytes,
      file_count: skill.file_count,
      source_kind: skill.source_kind,
      source_uri: skill.source_uri,
      source_rev: skill.source_rev
    }
  end

  defp metadata_from_map(entry) do
    Map.take(entry, [
      :id,
      :slug,
      :name,
      :description,
      :tags,
      :version,
      :license,
      :homepage,
      :author,
      :content_hash,
      :archive_ref,
      :size_bytes,
      :file_count,
      :source_kind,
      :source_uri,
      :source_rev
    ])
  end

  defp audit_skill_load(skill) do
    attrs = %{skill_name: skill.name, loaded_deps: []}

    if Application.get_env(:backplane, :env) == :test do
      Backplane.Audit.log_skill_load_sync(attrs)
    else
      Backplane.Audit.log_skill_load(attrs)
    end
  end

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
