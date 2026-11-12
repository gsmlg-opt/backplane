defmodule Backplane.Admin.Layouts do
  @moduledoc """
  Root and app layout components for the Backplane admin UI.
  """

  use Backplane.Admin, :html

  embed_templates("layouts/*")

  def top_nav_items do
    [
      %{label: dgettext("navigation", "Dashboard"), path: "/dashboard/overview", section: :dashboard},
      %{label: dgettext("navigation", "Llama"), path: "/llama/providers", section: :llama},
      %{label: dgettext("navigation", "MCP"), path: "/mcp/managed", section: :mcp},
      %{label: dgettext("navigation", "Memory"), path: "/memory", section: :memory},
      %{label: dgettext("navigation", "Skills"), path: "/skills", section: :skill},
      %{label: dgettext("navigation", "Plugins"), path: "/plugins", section: :plugins},
      %{label: dgettext("navigation", "Auth"), path: "/auth/overview", section: :auth},
      %{label: dgettext("navigation", "System"), path: "/system/clients", section: :system}
    ]
  end

  def left_nav_items(current_path) do
    case admin_section(current_path) do
      :dashboard ->
        [
          %{
            id: "overview",
            label: dgettext("navigation", "Overview"),
            icon: "view-dashboard-outline",
            items: [
              %{
                label: dgettext("navigation", "Overview"),
                path: "/dashboard/overview",
                icon: "view-dashboard-outline",
                match: :exact
              },
              %{label: dgettext("navigation", "LLM Usage"), path: "/dashboard/usage/llm", icon: "chart-line"},
              %{label: dgettext("navigation", "MCP Usage"), path: "/dashboard/usage/mcp", icon: "chart-bar"},
              %{label: dgettext("navigation", "Client Usage"), path: "/dashboard/usage/clients", icon: "account-chart"}
            ]
          },
          %{label: dgettext("navigation", "Plan Usage"), path: "/dashboard/usage/plans", icon: "chart-donut"},
          %{label: dgettext("navigation", "API Usage"), path: "/dashboard/usage/api", icon: "chart-line"}
        ]

      :llama ->
        [
          %{label: dgettext("navigation", "Providers"), path: "/llama/providers", icon: "cloud"},
          %{label: dgettext("navigation", "Model Alias"), path: "/llama/model-aliases", icon: "tune-vertical"},
          %{label: dgettext("navigation", "Codex Catalog"), path: "/llama/codex-catalog", icon: "robot-outline"},
          %{label: dgettext("navigation", "Decisions"), path: "/llama/openai/decisions", icon: "source-branch"},
          %{label: dgettext("navigation", "Images"), path: "/llama/openai/images", icon: "image-outline"},
          %{label: dgettext("navigation", "Embeddings"), path: "/llama/embedding", icon: "vector-point"},
          %{label: dgettext("navigation", "Text to Speech"), path: "/llama/openai/speech", icon: "account-voice"},
          %{label: dgettext("navigation", "Transcription"), path: "/llama/openai/transcription", icon: "microphone"},
          %{label: dgettext("navigation", "Realtime"), path: "/llama/openai/realtime", icon: "broadcast"},
          %{label: dgettext("navigation", "MiniMax Audio"), path: "/llama/audio", icon: "waveform"}
        ]

      :mcp ->
        [
          %{label: dgettext("navigation", "Managed MCP"), path: "/mcp/managed", icon: "server"},
          %{label: dgettext("navigation", "Upstream MCP"), path: "/mcp/upstreams", icon: "application-braces"},
          %{label: dgettext("navigation", "Agent MCP"), path: "/mcp/agent", icon: "robot"},
          %{label: dgettext("navigation", "MCP Inspector"), path: "/mcp/inspector", icon: "magnify-scan"}
        ]

      :memory ->
        [
          %{label: dgettext("navigation", "Overview"), path: "/memory", match: :exact, icon: "brain"},
          %{label: dgettext("navigation", "Records"), path: "/memory/records", icon: "notebook-outline"},
          %{label: dgettext("navigation", "Events"), path: "/memory/events", icon: "timeline-clock-outline"},
          %{label: dgettext("navigation", "Sessions"), path: "/memory/sessions", icon: "account-clock-outline"},
          %{label: dgettext("navigation", "Config"), path: "/memory/config", icon: "tune-variant"}
        ]

      :plugins ->
        [
          %{label: dgettext("navigation", "Catalog"), path: "/plugins", match: :exact, icon: "puzzle-outline"},
          %{label: dgettext("navigation", "Sources"), path: "/plugins/sources", icon: "source-repository"},
          %{label: dgettext("navigation", "Releases"), path: "/plugins/releases", icon: "package-variant"},
          %{label: dgettext("navigation", "Distribution"), path: "/plugins/distribution", icon: "share-variant"}
        ]

      :skill ->
        [
          %{
            label: dgettext("navigation", "Overview"),
            path: "/skills",
            match: :exact,
            icon: "view-dashboard-outline"
          },
          %{label: dgettext("navigation", "Skills"), path: "/skills/browse", icon: "book-open-variant"},
          %{label: dgettext("navigation", "Metadata"), path: "/skills/metadata", icon: "tag-multiple"},
          %{label: dgettext("navigation", "Upstream"), path: "/skills/upstream", icon: "cloud-download"},
          %{label: dgettext("navigation", "Draft"), path: "/skills/draft", icon: "pencil-box-outline"},
          %{label: dgettext("navigation", "Upload"), path: "/skills/upload", icon: "upload"}
        ]

      :auth ->
        [
          %{label: dgettext("navigation", "Overview"), path: "/auth/overview", icon: "view-dashboard-outline"},
          %{
            id: "oauth",
            label: dgettext("navigation", "OAuth"),
            icon: "shield-key",
            items: [
              %{label: dgettext("navigation", "Providers"), path: "/auth/oauth/providers", icon: "account-switch"},
              %{label: dgettext("navigation", "Clients"), path: "/auth/oauth/clients", icon: "application-braces"},
              %{
                label: dgettext("navigation", "Client Policies"),
                path: "/auth/oauth/client-policies",
                icon: "shield-check"
              },
              %{label: dgettext("navigation", "Tokens"), path: "/auth/oauth/tokens", icon: "key-chain"},
              %{label: dgettext("navigation", "Scopes"), path: "/auth/oauth/scopes", icon: "format-list-checks"},
              %{label: dgettext("navigation", "Protocol Support"), path: "/auth/oauth/protocol-support", icon: "protocol"}
            ]
          },
          %{
            id: "rbac",
            label: dgettext("navigation", "RBAC"),
            icon: "account-key",
            items: [
              %{label: dgettext("navigation", "Users"), path: "/auth/rbac/users", icon: "account-group"},
              %{label: dgettext("navigation", "Roles"), path: "/auth/rbac/roles", icon: "account-cog"},
              %{
                label: dgettext("navigation", "Assignments"),
                path: "/auth/rbac/assignments",
                icon: "account-multiple-check"
              }
            ]
          },
          %{label: dgettext("navigation", "Audit"), path: "/auth/audit", icon: "text-box-search"}
        ]

      :system ->
        [
          %{label: dgettext("navigation", "Config"), path: "/system/config", icon: "tune-variant"},
          %{label: dgettext("navigation", "Appearance"), path: "/system/appearance", icon: "palette-outline"},
          %{label: dgettext("navigation", "Clients"), path: "/system/clients", icon: "account-group"},
          %{label: dgettext("navigation", "Endpoints"), path: "/system/endpoints", icon: "lan-connect"},
          %{label: dgettext("navigation", "Credentials"), path: "/system/credentials", icon: "key-variant"},
          %{
            label: dgettext("navigation", "Host Agents"),
            path: "/system/host-agents",
            icon: "server"
          },
          %{
            id: "monitor",
            label: dgettext("navigation", "Monitor"),
            icon: "monitor-eye",
            items: [
              %{
                label: dgettext("navigation", "Plan Usage"),
                path: "/system/monitor/plans",
                icon: "chart-donut"
              },
              %{
                label: dgettext("navigation", "API Usage"),
                path: "/system/monitor/api-usage",
                icon: "chart-line"
              }
            ]
          },
          %{
            id: "log",
            label: dgettext("navigation", "Log"),
            icon: "text-box-search",
            items: [
              %{label: dgettext("navigation", "LLM Log"), path: "/system/logs/llm", icon: "chart-line"},
              %{label: dgettext("navigation", "MCP Log"), path: "/system/logs/mcp", icon: "chart-bar"},
              %{label: dgettext("navigation", "Audit Log"), path: "/system/logs/audit", icon: "text-box-search-outline"},
              %{label: dgettext("navigation", "Job"), path: "/system/logs/jobs", icon: "cog-clockwise"},
              %{label: dgettext("navigation", "Sink"), path: "/system/logs/sinks", icon: "pipe"}
            ]
          }
        ]
    end
  end

  def left_nav_groups(current_path) do
    current_path
    |> left_nav_items()
    |> Enum.chunk_by(fn item -> if Map.has_key?(item, :items), do: item.label end)
    |> Enum.map(fn
      [%{items: items} = group] ->
        %{
          id: group.id,
          label: group.label,
          items: Enum.map(items, &left_menu_item/1)
        }

      items ->
        %{
          id: "links-" <> left_nav_item_id(hd(items)),
          label: left_nav_heading(current_path),
          items: Enum.map(items, &left_menu_item/1)
        }
    end)
  end

  def active_left_nav_id(current_path) do
    current_path
    |> left_nav_items()
    |> Enum.flat_map(fn item -> Map.get(item, :items, [item]) end)
    |> Enum.find_value("", fn item ->
      if active_left_nav?(current_path, item), do: left_nav_item_id(item)
    end)
  end

  defp left_menu_item(item) do
    %{id: left_nav_item_id(item), label: item.label, to: item.path, icon: item.icon}
  end

  defp left_nav_item_id(item) do
    item.path |> String.trim_leading("/") |> String.replace("/", "-")
  end

  def left_nav_heading(current_path) do
    case admin_section(current_path) do
      :dashboard -> dgettext("navigation", "Dashboard")
      :llama -> dgettext("navigation", "LLM Proxy")
      :mcp -> dgettext("navigation", "MCP Hub")
      :memory -> dgettext("navigation", "Memory")
      :skill -> dgettext("navigation", "Skills")
      :plugins -> dgettext("navigation", "Plugins")
      :auth -> dgettext("navigation", "Auth")
      :system -> dgettext("navigation", "System")
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
      String.starts_with?(current_path, "/plugins") -> :plugins
      skill_path?(current_path) -> :skill
      String.starts_with?(current_path, "/auth") -> :auth
      String.starts_with?(current_path, "/system") -> :system
      true -> :dashboard
    end
  end

  defp skill_path?(current_path) do
    current_path == "/skill" or current_path == "/skills" or
      String.starts_with?(current_path, "/skills/")
  end
end
