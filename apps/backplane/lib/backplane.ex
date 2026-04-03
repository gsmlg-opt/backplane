defmodule Backplane do
  @moduledoc """
  Backplane - A self-hosted MCP gateway.

  Presents a single MCP Streamable HTTP endpoint that aggregates:
  - MCP Proxy (upstream MCP servers)
  - Skills Hub (curated instruction packages)
  - Doc Server (documentation search)
  - Git Platform Proxy (GitHub + GitLab)
  - Hub Meta (cross-cutting discovery)

  This module provides the public API for programmatic access.
  """

  alias Backplane.Docs.Search
  alias Backplane.Hub.Discover
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @doc "Search documentation for a project."
  defdelegate search_docs(project_id, query, opts \\ []), to: Search, as: :query

  @doc "Unified discovery across tools, skills, docs, and repos."
  defdelegate discover(query, opts \\ []), to: Discover, as: :search

  @doc "List all registered tools."
  def list_tools, do: ToolRegistry.list_all()

  @doc "Count registered tools."
  def tool_count, do: ToolRegistry.count()

  @doc "Search skills by query."
  def search_skills(query, opts \\ []), do: SkillsRegistry.search(query, opts)

  @doc "Count registered skills."
  def skill_count, do: SkillsRegistry.count()

  @doc "Get the current version from mix.exs."
  def version do
    Application.spec(:backplane, :vsn) |> to_string()
  end

  @doc "MCP protocol version supported by this server."
  def protocol_version, do: "2025-03-26"
end
