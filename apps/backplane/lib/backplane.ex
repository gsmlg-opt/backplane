defmodule Backplane do
  @moduledoc """
  Backplane - A self-hosted MCP gateway.

  Two features:
  - MCP Hub (upstream MCP servers + managed services)
  - LLM Proxy (credential-injecting reverse proxy)
  """

  alias Backplane.Hub.Discover
  alias Backplane.Registry.ToolRegistry
  alias Backplane.Skills.Registry, as: SkillsRegistry

  @doc "Unified discovery across tools and skills."
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
