defmodule Backplane.Api.PageController do
  use Backplane.Api, :controller

  alias Backplane.WebOrigins

  @doc_sections [
    %{
      slug: "llama",
      label: "LLM proxy",
      heading: "LLM proxy",
      summary:
        "Route OpenAI-compatible and Anthropic-compatible model traffic through Backplane while keeping credentials and model aliases server-side.",
      entries: [
        %{
          title: "OpenAI-compatible endpoint",
          body:
            "Use /v1/models for the OpenAI-format list of exposed models and aliases, then send chat, responses, and embeddings requests through /v1/*."
        },
        %{
          title: "Anthropic Messages",
          body:
            "Use /v1/messages for Anthropic Messages-compatible clients. Configure the client base URL to the API origin."
        },
        %{
          title: "Model routing",
          body:
            "Backplane resolves model aliases, injects upstream provider credentials, and records usage behind the gateway."
        }
      ],
      routes: [
        "GET /v1/models",
        "POST /v1/messages",
        "POST /v1/chat/completions",
        "POST /v1/responses",
        "POST /v1/embeddings"
      ]
    },
    %{
      slug: "mcp",
      label: "MCP hub",
      heading: "MCP hub",
      summary:
        "Connect MCP clients to one Backplane endpoint and access upstream servers, managed services, and hub tools with namespaced tool names.",
      entries: [
        %{
          title: "Streamable HTTP endpoint",
          body: "JSON-RPC requests: initialize, tools/list, tools/call, ping."
        },
        %{
          title: "Notification stream",
          body: "Server-sent event stream for MCP notifications."
        },
        %{
          title: "Session cleanup",
          body: "DELETE /mcp cleans up clients that maintain an MCP session id."
        },
        %{
          title: "Tool namespaces",
          body:
            "Every tool is exposed as prefix::tool_name, keeping upstream and managed tools stable for clients."
        },
        %{
          title: "Client access",
          body: "Client bearer tokens can restrict which MCP tools a caller is allowed to invoke."
        }
      ],
      routes: ["POST /mcp", "GET /mcp", "DELETE /mcp"]
    },
    %{
      slug: "skills",
      label: "Skills library",
      heading: "Skills library",
      summary:
        "Serve, import, export, and browse reusable agent skills through both the public Skills API and MCP tools.",
      entries: [
        %{
          title: "Skill archive routes",
          body:
            "Use /skills to list or create records, /skills/export for a bundle, and /skills/:slug/archive for a single archive."
        },
        %{
          title: "Managed service tools",
          body:
            "The skills managed service exposes skill discovery and retrieval through MCP for connected agents."
        },
        %{
          title: "Host-agent support",
          body:
            "The host-agent socket can synchronize local skill and memory context with Backplane."
        }
      ],
      routes: [
        "GET /skills",
        "POST /skills",
        "GET /skills/export",
        "POST /skills/import",
        "GET /skills/:slug",
        "GET /skills/:slug/archive",
        "DELETE /skills/:slug"
      ]
    },
    %{
      slug: "agents",
      label: "Agent setup",
      heading: "Agent setup",
      summary:
        "Point coding agents and API clients at Backplane for model calls, MCP tools, and optional client authentication.",
      entries: [
        %{
          title: "Claude Code",
          body:
            "Set ANTHROPIC_BASE_URL to the Backplane API origin, export ANTHROPIC_API_KEY, then run claude mcp add --transport http backplane <base-url>/mcp."
        },
        %{
          title: "Codex",
          body:
            "Set openai_base_url to the /v1 origin in ~/.codex/config.toml and configure mcp_servers.backplane with the Backplane MCP server URL."
        },
        %{
          title: "Tokens",
          body:
            "Use bearer token environment variables when this deployment has MCP clients or LLM proxy credentials enabled."
        }
      ],
      routes: ["ANTHROPIC_BASE_URL", "openai_base_url", "mcp_servers.backplane"]
    },
    %{
      slug: "auth",
      label: "Authentication",
      heading: "Authentication",
      summary:
        "Backplane supports client token enforcement for MCP access and OAuth endpoints for browser and API authentication flows.",
      entries: [
        %{
          title: "Bearer token",
          body:
            "Send Authorization: Bearer <token> when client mode is enabled for MCP or model gateway calls."
        },
        %{
          title: "Open mode",
          body:
            "If no MCP clients and no legacy token are configured, local development MCP access remains open."
        },
        %{
          title: "OAuth endpoints",
          body:
            "The public API app owns the authorization, login, token, introspection, revoke, userinfo, and JWKS endpoints."
        }
      ],
      routes: [
        "GET /oauth/authorize",
        "POST /oauth/token",
        "POST /oauth/introspect",
        "POST /oauth/revoke",
        "GET /oauth/userinfo",
        "GET /oauth/jwks"
      ]
    }
  ]

  def home(conn, _params) do
    conn
    |> assign(:page_title, "Backplane")
    |> assign(:base_url, WebOrigins.api_base_url())
    |> put_layout(html: false)
    |> render(:home)
  end

  def docs(conn, %{"section" => slug}) do
    case Enum.find(@doc_sections, &(&1.slug == slug)) do
      nil -> send_resp(conn, 404, "not found")
      section -> render_docs(conn, section)
    end
  end

  def docs(conn, _params) do
    render_docs(conn, nil)
  end

  defp render_docs(conn, selected_section) do
    conn
    |> assign(:page_title, docs_page_title(selected_section))
    |> assign(:base_url, WebOrigins.api_base_url())
    |> assign(:doc_sections, @doc_sections)
    |> assign(:selected_section, selected_section)
    |> put_layout(html: false)
    |> render(:docs)
  end

  defp docs_page_title(nil), do: "Backplane Docs"
  defp docs_page_title(section), do: "#{section.heading} - Backplane Docs"
end
