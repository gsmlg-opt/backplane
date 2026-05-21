defmodule Backplane.Tools.Skill do
  @moduledoc """
  Native MCP tools for the Skills engine.
  Registers: skill::search, skill::load, skill::list, skill::download, skill::publish
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Skills
  alias Backplane.Skills.Archive
  alias Backplane.Skills.Skill, as: SkillSchema
  alias Backplane.Utils

  @impl true
  def tools do
    [
      %{
        name: "skill::search",
        description: "Search available archive-backed skills by keyword and tags",
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
          "Load a skill archive by slug, including SKILL.md, meta.json, files, and metadata",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "slug" => %{"type" => "string", "description" => "Skill slug"},
            "skill_id" => %{"type" => "string", "description" => "Legacy skill ID fallback"}
          },
          "required" => ["slug"]
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
        description: "Return metadata and archive URL for a skill archive",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "slug" => %{"type" => "string", "description" => "Skill slug"}
          },
          "required" => ["slug"]
        },
        module: __MODULE__,
        handler: :download
      },
      %{
        name: "skill::publish",
        description: "Publish a skill from a base64-encoded .tar.gz archive",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "archive_base64" => %{
              "type" => "string",
              "description" => "Base64-encoded .tar.gz archive bytes"
            }
          },
          "required" => ["archive_base64"]
        },
        module: __MODULE__,
        handler: :publish
      }
    ]
  end

  @impl true
  @spec call(map()) :: {:ok, term()} | {:error, term()}
  def call(%{"_handler" => "search"} = args) do
    opts = search_opts(args)

    results = Skills.search(args["query"], opts)
    {:ok, results}
  end

  def call(%{"_handler" => "load"} = args) do
    args
    |> skill_ref()
    |> fetch_skill()
    |> case do
      {:ok, skill} -> load_archive_skill(skill)
      {:error, :not_found} -> {:error, "Skill not found: #{skill_ref(args)}"}
    end
  end

  def call(%{"_handler" => "list"} = args) do
    skills =
      Skills.list()
      |> filter_tags(args["tags"])
      |> maybe_limit(args["limit"])
      |> Enum.map(&metadata/1)

    {:ok, skills}
  end

  def call(%{"_handler" => "download"} = args) do
    args
    |> skill_ref()
    |> fetch_skill()
    |> case do
      {:ok, skill} -> download_metadata(skill)
      {:error, :not_found} -> {:error, "Skill not found: #{skill_ref(args)}"}
    end
  end

  def call(%{"_handler" => "publish", "archive_base64" => archive_base64}) do
    with {:ok, archive_bytes} <- Base.decode64(archive_base64),
         {:ok, path} <- write_temp_archive(archive_bytes),
         {:ok, skill} <- ingest_temp_archive(path) do
      {:ok, metadata(skill)}
    else
      :error -> {:error, "Invalid base64 archive"}
      {:error, reason} -> {:error, "Failed to publish skill archive: #{inspect(reason)}"}
    end
  end

  # Default handler — route based on tool name
  def call(args) do
    {:error, "Unknown skill tool handler: #{inspect(args)}"}
  end

  defp search_opts(args) do
    []
    |> maybe_add(:tags, args["tags"])
    |> maybe_add(:limit, args["limit"])
  end

  defp skill_ref(args), do: args["slug"] || args["skill_id"] || ""

  defp fetch_skill(slug_or_id) when is_binary(slug_or_id) and slug_or_id != "" do
    case Skills.get_by_slug(slug_or_id) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> Skills.get(slug_or_id)
    end
  end

  defp fetch_skill(_), do: {:error, :not_found}

  defp load_archive_skill(%SkillSchema{} = skill) do
    with {:ok, inspected} <- inspect_archive(skill) do
      {:ok,
       skill
       |> metadata()
       |> Map.merge(%{
         skill_md: inspected.skill_md,
         meta_json: inspected.meta,
         files: inspected.files,
         size_bytes: inspected.size_bytes,
         file_count: inspected.file_count
       })}
    else
      {:error, reason} -> {:error, "Failed to load skill archive: #{inspect(reason)}"}
    end
  end

  defp download_metadata(%SkillSchema{} = skill) do
    {:ok,
     %{
       archive_url: "/api/skills/#{URI.encode(skill.slug)}/archive",
       content_hash: skill.content_hash,
       size_bytes: skill.size_bytes,
       metadata: metadata(skill)
     }}
  end

  defp inspect_archive(%SkillSchema{} = skill) do
    with {:ok, stream} <- Skills.archive_stream(skill),
         {:ok, path} <- write_stream_to_temp(stream) do
      try do
        Archive.inspect(path)
      after
        File.rm(path)
      end
    end
  end

  defp write_stream_to_temp(stream) do
    path = temp_archive_path()

    case File.open(path, [:write, :binary], fn io ->
           Enum.each(stream, &IO.binwrite(io, &1))
         end) do
      {:ok, :ok} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_temp_archive(bytes) when is_binary(bytes) do
    path = temp_archive_path()

    case File.write(path, bytes, [:binary]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest_temp_archive(path) do
    try do
      Skills.ingest_archive(path, [])
    after
      File.rm(path)
    end
  end

  defp temp_archive_path do
    Path.join(
      System.tmp_dir!(),
      "backplane-skill-tool-#{System.unique_integer([:positive])}.tar.gz"
    )
  end

  defp filter_tags(skills, tags) when tags in [nil, []], do: skills

  defp filter_tags(skills, tags) when is_list(tags) do
    tag_set = MapSet.new(tags)

    Enum.filter(skills, fn skill ->
      skill_tags = skill.tags || []
      MapSet.subset?(tag_set, MapSet.new(skill_tags))
    end)
  end

  defp maybe_limit(skills, limit) when is_integer(limit), do: Enum.take(skills, max(limit, 0))
  defp maybe_limit(skills, _limit), do: skills

  defp metadata(%SkillSchema{} = skill) do
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
      meta: skill.meta,
      content_hash: skill.content_hash,
      archive_ref: skill.archive_ref,
      size_bytes: skill.size_bytes,
      file_count: skill.file_count,
      source_kind: skill.source_kind
    }
  end

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
