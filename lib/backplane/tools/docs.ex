defmodule Backplane.Tools.Docs do
  @moduledoc """
  Native MCP tools for the Doc Engine.
  Registers: docs::resolve-project, docs::query-docs
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Docs.{Project, Search}
  alias Backplane.Repo
  alias Backplane.Utils

  import Ecto.Query

  @impl true
  def tools do
    [
      %{
        name: "docs::resolve-project",
        description:
          "Fuzzy match a project by name or repo URL. Returns matching project IDs and metadata.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Project name or partial repo URL to search for"
            }
          },
          "required" => ["query"]
        },
        module: __MODULE__,
        handler: :resolve_project
      },
      %{
        name: "docs::query-docs",
        description:
          "Search documentation chunks for a project using full-text search. Returns ranked results within a token budget.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{
              "type" => "string",
              "description" => "Project ID to search within"
            },
            "query" => %{
              "type" => "string",
              "description" => "Search query text"
            },
            "max_tokens" => %{
              "type" => "integer",
              "description" => "Maximum token budget for results (default 8000)"
            },
            "chunk_type" => %{
              "type" => "string",
              "description" =>
                "Filter by chunk type: moduledoc, function_doc, typespec, guide, code"
            },
            "version" => %{
              "type" => "string",
              "description" =>
                "Git ref to query. Defaults to the project's configured ref. (Reserved for multi-version support)"
            }
          },
          "required" => ["project_id", "query"]
        },
        module: __MODULE__,
        handler: :query_docs
      }
    ]
  end

  @impl true
  @spec call(map()) :: {:ok, term()} | {:error, term()}
  def call(%{"_handler" => "resolve_project"} = args) do
    query = args["query"]

    escaped = Utils.escape_like(query)

    pattern = "%#{escaped}%"

    downcased = String.downcase(query)
    exact_pattern = downcased

    results =
      Project
      |> where(
        [p],
        ilike(p.id, ^pattern) or ilike(p.repo, ^pattern) or
          ilike(p.description, ^pattern)
      )
      |> order_by(
        [p],
        asc:
          fragment(
            "CASE WHEN LOWER(?) = ? THEN 0 WHEN LOWER(?) LIKE ? THEN 1 WHEN LOWER(?) LIKE ? THEN 2 ELSE 3 END",
            p.id,
            ^exact_pattern,
            p.id,
            ^pattern,
            p.repo,
            ^pattern
          )
      )
      |> limit(5)
      |> select([p], %{
        id: p.id,
        repo: p.repo,
        ref: p.ref,
        description: p.description,
        last_indexed_at: p.last_indexed_at
      })
      |> Repo.all()

    {:ok, %{projects: results, count: length(results)}}
  end

  def call(%{"_handler" => "query_docs"} = args) do
    project_id = args["project_id"]
    query = args["query"]
    version = args["version"]

    with :ok <- validate_version(project_id, version) do
      opts =
        []
        |> maybe_add(:max_tokens, args["max_tokens"])
        |> maybe_add(:chunk_type, args["chunk_type"])

      results = Search.query(project_id, query, opts)

      formatted =
        Enum.map(results, fn r ->
          %{
            source_path: r.source_path,
            module: r.module,
            function: r.function,
            chunk_type: r.chunk_type,
            content: r.content,
            tokens: r.tokens,
            score: r.rank
          }
        end)

      total_tokens = Enum.reduce(formatted, 0, fn r, acc -> acc + (r.tokens || 0) end)

      {:ok, %{results: formatted, count: length(formatted), total_tokens: total_tokens}}
    end
  end

  def call(args) do
    {:error, "Unknown docs tool handler: #{inspect(args)}"}
  end

  defp validate_version(_project_id, nil), do: :ok

  defp validate_version(project_id, version) do
    case Repo.get(Project, project_id) do
      nil ->
        {:error,
         "Project '#{project_id}' not found. Use docs::resolve-project to find available projects."}

      project ->
        if project.ref == version do
          :ok
        else
          {:error,
           "Version '#{version}' not indexed. Project '#{project_id}' is indexed at ref '#{project.ref}'. " <>
             "Multi-version support is not yet available."}
        end
    end
  end

  defp maybe_add(opts, key, value), do: Utils.maybe_put(opts, key, value)
end
