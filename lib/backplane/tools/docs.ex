defmodule Backplane.Tools.Docs do
  @moduledoc """
  Native MCP tools for the Doc Engine.
  Registers: docs::resolve-project, docs::query-docs
  """

  alias Backplane.Docs.{Project, Search}
  alias Backplane.Repo

  import Ecto.Query

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
            }
          },
          "required" => ["project_id", "query"]
        },
        module: __MODULE__,
        handler: :query_docs
      }
    ]
  end

  def call(%{"_handler" => "resolve_project"} = args) do
    query = args["query"]
    pattern = "%#{query}%"

    results =
      Project
      |> where([p], ilike(p.id, ^pattern) or ilike(p.repo, ^pattern))
      |> limit(10)
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
          tokens: r.tokens
        }
      end)

    total_tokens = Enum.sum(Enum.map(formatted, & &1.tokens) |> Enum.map(&(&1 || 0)))

    {:ok, %{results: formatted, count: length(formatted), total_tokens: total_tokens}}
  end

  def call(args) do
    {:error, "Unknown docs tool handler: #{inspect(args)}"}
  end

  defp maybe_add(opts, key, value), do: Backplane.Utils.maybe_put(opts, key, value)
end
