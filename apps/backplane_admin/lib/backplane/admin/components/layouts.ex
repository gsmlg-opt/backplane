defmodule Backplane.Admin.Layouts do
  @moduledoc """
  Root and app layout components for the Backplane admin UI.
  """

  use Backplane.Admin, :html

  embed_templates("layouts/*")

  def top_nav_items do
    [
      %{label: "Dashboard", path: "/dashboard/overview", section: :dashboard},
      %{label: "Llama", path: "/llama/providers", section: :llama},
      %{label: "MCP", path: "/mcp/managed", section: :mcp},
      %{label: "Memory", path: "/memory", section: :memory},
      %{label: "Skills", path: "/skills", section: :skill},
      %{label: "System", path: "/system/clients", section: :system}
    ]
  end

  def left_nav_items(current_path) do
    case admin_section(current_path) do
      :dashboard ->
        [
          %{label: "Overview", path: "/dashboard/overview", icon: "view-dashboard-outline"},
          %{label: "LLM Usage", path: "/dashboard/usage/llm", icon: "chart-line"},
          %{label: "MCP Usage", path: "/dashboard/usage/mcp", icon: "chart-bar"},
          %{label: "Plan Usage", path: "/dashboard/usage/plans", icon: "chart-donut"}
        ]

      :llama ->
        [
          %{label: "Providers", path: "/llama/providers", icon: "cloud"},
          %{label: "Embedding", path: "/llama/embedding", icon: "vector-point"},
          %{label: "Model Alias", path: "/llama/model-aliases", icon: "tune-vertical"}
        ]

      :mcp ->
        [
          %{label: "Managed MCP", path: "/mcp/managed", icon: "server"},
          %{label: "Upstream MCP", path: "/mcp/upstreams", icon: "application-braces"},
          %{label: "Agent MCP", path: "/mcp/agent", icon: "robot"},
          %{label: "MCP Inspector", path: "/mcp/inspector", icon: "magnify-scan"}
        ]

      :memory ->
        [
          %{label: "Overview", path: "/memory", match: :exact, icon: "brain"},
          %{label: "Browse", path: "/memory/browse", icon: "database-search"},
          %{label: "Stats", path: "/memory/stats", icon: "chart-bar"},
          %{label: "Observations", path: "/memory/observations", icon: "text-box-search"},
          %{label: "Sessions", path: "/memory/sessions", icon: "history"},
          %{label: "Graph", path: "/memory/graph", icon: "graph"},
          %{label: "Actions", path: "/memory/actions", icon: "application-braces"},
          %{label: "Audit", path: "/memory/audit", icon: "shield-key"},
          %{label: "Config", path: "/memory/config", icon: "cog"}
        ]

      :skill ->
        [
          %{
            label: "Overview",
            path: "/skills",
            match: :exact,
            icon: "view-dashboard-outline"
          },
          %{label: "Skills", path: "/skills/browse", icon: "book-open-variant"},
          %{label: "Metadata", path: "/skills/metadata", icon: "tag-multiple"},
          %{label: "Upstream", path: "/skills/upstream", icon: "cloud-download"},
          %{label: "Draft", path: "/skills/draft", icon: "pencil-box-outline"},
          %{label: "Upload", path: "/skills/upload", icon: "upload"}
        ]

      :system ->
        [
          %{label: "Clients", path: "/system/clients", icon: "account-group"},
          %{label: "Credentials", path: "/system/credentials", icon: "key-variant"},
          %{
            label: "Monitor",
            icon: "monitor-eye",
            items: [
              %{
                label: "Logs",
                path: "/system/logs",
                icon: "text-box-search"
              },
              %{
                label: "Plan Usage",
                path: "/system/monitor/plans",
                icon: "chart-donut"
              }
            ]
          },
          %{
            label: "Host Agents",
            path: "/system/host-agents",
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
      String.starts_with?(current_path, "/dashboard") -> :dashboard
      String.starts_with?(current_path, "/llama") -> :llama
      String.starts_with?(current_path, "/mcp") -> :mcp
      String.starts_with?(current_path, "/memory") -> :memory
      skill_path?(current_path) -> :skill
      String.starts_with?(current_path, "/system") -> :system
      true -> :dashboard
    end
  end

  defp skill_path?(current_path) do
    current_path == "/skill" or current_path == "/skills" or
      String.starts_with?(current_path, "/skills/")
  end
end
