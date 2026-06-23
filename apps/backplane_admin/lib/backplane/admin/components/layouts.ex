defmodule Backplane.Admin.Layouts do
  @moduledoc """
  Root and app layout components for the Backplane admin UI.
  """

  use Backplane.Admin, :html

  embed_templates("layouts/*")

  def top_nav_items do
    [
      %{label: "Dashboard", path: "/admin/dashboard/overview", section: :dashboard},
      %{label: "Llama", path: "/admin/llama/providers", section: :llama},
      %{label: "MCP", path: "/admin/mcp/managed", section: :mcp},
      %{label: "Memory", path: "/admin/memory", section: :memory},
      %{label: "Skills", path: "/admin/skills", section: :skill},
      %{label: "System", path: "/admin/system/clients", section: :system}
    ]
  end

  def left_nav_items(current_path) do
    case admin_section(current_path) do
      :dashboard ->
        [
          %{label: "Overview", path: "/admin/dashboard/overview", icon: "view-dashboard-outline"},
          %{label: "LLM Usage", path: "/admin/dashboard/usage/llm", icon: "chart-line"},
          %{label: "MCP Usage", path: "/admin/dashboard/usage/mcp", icon: "chart-bar"},
          %{label: "Plan Usage", path: "/admin/dashboard/usage/plans", icon: "chart-donut"}
        ]

      :llama ->
        [
          %{label: "Providers", path: "/admin/llama/providers", icon: "cloud"},
          %{label: "Embedding", path: "/admin/llama/embedding", icon: "vector-point"},
          %{label: "Model Alias", path: "/admin/llama/model-aliases", icon: "tune-vertical"}
        ]

      :mcp ->
        [
          %{label: "Managed MCP", path: "/admin/mcp/managed", icon: "server"},
          %{label: "Upstream MCP", path: "/admin/mcp/upstreams", icon: "application-braces"},
          %{label: "Agent MCP", path: "/admin/mcp/agent", icon: "robot"},
          %{label: "MCP Inspector", path: "/admin/mcp/inspector", icon: "magnify-scan"}
        ]

      :memory ->
        [
          %{label: "Overview", path: "/admin/memory", match: :exact, icon: "brain"},
          %{label: "Browse", path: "/admin/memory/browse", icon: "database-search"},
          %{label: "Stats", path: "/admin/memory/stats", icon: "chart-bar"},
          %{label: "Observations", path: "/admin/memory/observations", icon: "text-box-search"},
          %{label: "Sessions", path: "/admin/memory/sessions", icon: "history"},
          %{label: "Graph", path: "/admin/memory/graph", icon: "graph"},
          %{label: "Actions", path: "/admin/memory/actions", icon: "application-braces"},
          %{label: "Audit", path: "/admin/memory/audit", icon: "shield-key"},
          %{label: "Config", path: "/admin/memory/config", icon: "cog"}
        ]

      :skill ->
        [
          %{
            label: "Overview",
            path: "/admin/skills",
            match: :exact,
            icon: "view-dashboard-outline"
          },
          %{label: "Skills", path: "/admin/skills/browse", icon: "book-open-variant"},
          %{label: "Metadata", path: "/admin/skills/metadata", icon: "tag-multiple"},
          %{label: "Upstream", path: "/admin/skills/upstream", icon: "cloud-download"},
          %{label: "Draft", path: "/admin/skills/draft", icon: "pencil-box-outline"},
          %{label: "Upload", path: "/admin/skills/upload", icon: "upload"}
        ]

      :system ->
        [
          %{label: "Clients", path: "/admin/system/clients", icon: "account-group"},
          %{label: "Credentials", path: "/admin/system/credentials", icon: "key-variant"},
          %{
            label: "Monitor",
            icon: "monitor-eye",
            items: [
              %{
                label: "Logs",
                path: "/admin/system/logs",
                icon: "text-box-search"
              },
              %{
                label: "Plan Usage",
                path: "/admin/system/monitor/plans",
                icon: "chart-donut"
              }
            ]
          },
          %{
            label: "Host Agents",
            path: "/admin/system/host-agents",
            icon: "server"
          }
        ]
    end
  end

  def left_nav_heading(current_path) do
    case admin_section(current_path) do
      :dashboard -> "Dashboard"
      :llama -> "LLM Proxy"
      :mcp -> "MCP Hub"
      :memory -> "Memory"
      :skill -> "Skills"
      :system -> "System"
    end
  end

  def active_top_nav?(current_path, section) do
    admin_section(current_path) == section
  end

  def active_left_nav?(current_path, %{path: path, match: :exact}) do
    current_path == path
  end

  def active_left_nav?(current_path, %{path: path}) do
    active_left_nav?(current_path, path)
  end

  def active_left_nav?(current_path, path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end

  defp admin_section(current_path) do
    cond do
      String.starts_with?(current_path, "/admin/dashboard") -> :dashboard
      String.starts_with?(current_path, "/admin/llama") -> :llama
      String.starts_with?(current_path, "/admin/mcp") -> :mcp
      String.starts_with?(current_path, "/admin/memory") -> :memory
      skill_path?(current_path) -> :skill
      String.starts_with?(current_path, "/admin/system") -> :system
      true -> :dashboard
    end
  end

  defp skill_path?(current_path) do
    current_path == "/admin/skill" or current_path == "/admin/skills" or
      String.starts_with?(current_path, "/admin/skills/")
  end
end
