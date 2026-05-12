defmodule BackplaneWeb.Layouts do
  @moduledoc """
  Root and app layout components for the Backplane admin UI.
  """

  use BackplaneWeb, :html

  embed_templates("layouts/*")

  def top_nav_items do
    [
      %{label: "Dashboard", path: "/admin/dashboard/overview", section: :dashboard},
      %{label: "Llama", path: "/admin/llama/providers", section: :llama},
      %{label: "MCP", path: "/admin/mcp/managed", section: :mcp},
      %{label: "Skill", path: "/admin/skill", section: :skill},
      %{label: "System", path: "/admin/system/clients", section: :system}
    ]
  end

  def left_nav_items(current_path) do
    case admin_section(current_path) do
      :dashboard ->
        [
          %{label: "Overview", path: "/admin/dashboard/overview"},
          %{label: "LLM Usage", path: "/admin/dashboard/usage/llm"},
          %{label: "MCP Usage", path: "/admin/dashboard/usage/mcp"}
        ]

      :llama ->
        [
          %{label: "Providers", path: "/admin/llama/providers"},
          %{label: "Model Alias", path: "/admin/llama/model-aliases"}
        ]

      :mcp ->
        [
          %{label: "Managed MCP", path: "/admin/mcp/managed"},
          %{label: "Upstream MCP", path: "/admin/mcp/upstreams"}
        ]

      :skill ->
        []

      :system ->
        [
          %{label: "Clients", path: "/admin/system/clients"},
          %{label: "Logs", path: "/admin/system/logs"},
          %{label: "Credentials", path: "/admin/system/credentials"}
        ]
    end
  end

  def active_top_nav?(current_path, section) do
    admin_section(current_path) == section
  end

  def active_left_nav?(current_path, path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end

  defp admin_section(current_path) do
    cond do
      String.starts_with?(current_path, "/admin/dashboard") -> :dashboard
      String.starts_with?(current_path, "/admin/llama") -> :llama
      String.starts_with?(current_path, "/admin/mcp") -> :mcp
      String.starts_with?(current_path, "/admin/skill") -> :skill
      String.starts_with?(current_path, "/admin/system") -> :system
      true -> :dashboard
    end
  end
end
