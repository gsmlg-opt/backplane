defmodule Backplane.Api.PageController do
  use Backplane.Api, :controller

  alias Backplane.WebOrigins

  @doc_aliases %{"auth" => "authentication", "llama" => "llm"}

  def home(conn, _params) do
    base_url = WebOrigins.api_base_url()

    conn
    |> assign(:page_title, "Backplane")
    |> assign(:base_url, base_url)
    |> put_layout(html: false)
    |> render(:home)
  end

  def docs(conn, params) do
    base_url = WebOrigins.api_base_url()
    sections = doc_sections(base_url)

    case selected_section(params, sections) do
      :not_found -> send_resp(conn, 404, "not found")
      selected_section -> render_docs(conn, selected_section, sections, base_url)
    end
  end

  defp selected_section(%{"section" => requested_slug}, sections) do
    slug = Map.get(@doc_aliases, requested_slug, requested_slug)
    Enum.find(sections, :not_found, &(&1.slug == slug))
  end

  defp selected_section(_params, _sections), do: nil

  defp render_docs(conn, selected_section, sections, base_url) do
    conn
    |> assign(:page_title, docs_page_title(selected_section))
    |> assign(:base_url, base_url)
    |> assign(:doc_sections, sections)
    |> assign(:selected_section, selected_section)
    |> put_layout(html: false)
    |> render(:docs)
  end

  defp docs_page_title(nil), do: "Backplane Docs"
  defp docs_page_title(section), do: "#{section.heading} - Backplane Docs"

  defp doc_sections(base_url) do
    mcp_url = join_url(base_url, "/mcp")
    mcp_metadata_url = join_url(base_url, "/.well-known/oauth-protected-resource/mcp")
    v1_url = join_url(base_url, "/v1")
    v1_metadata_url = join_url(base_url, "/.well-known/oauth-protected-resource/v1")
    authorize_url = join_url(base_url, "/oauth/authorize")
    token_url = join_url(base_url, "/oauth/token")
    revoke_url = join_url(base_url, "/oauth/revoke")

    [
      %{
        slug: "mcp",
        label: "MCP hub",
        heading: "MCP hub",
        summary:
          "Connect ChatGPT and other MCP clients to Backplane's resource-bound tool gateway.",
        entries: [
          %{
            title: "One protected MCP resource",
            body:
              "#{mcp_url} is the canonical Streamable HTTP endpoint. An unauthenticated request returns a WWW-Authenticate challenge that points to #{mcp_metadata_url}."
          },
          %{
            title: "Scoped access",
            body:
              "Assign the same MCP tool scopes to the predefined client and the signing-in user. Backplane exposes permitted tools with stable prefix::tool names."
          }
        ],
        steps: [
          "Copy the exact callback URI shown in the ChatGPT app-management page. It has a shape such as https://chatgpt.com/connector/oauth/<callback_id>. Do not change the callback ID or add a trailing slash.",
          "Create a predefined confidential Backplane OAuth client, keep PKCE S256 enabled, and register that exact callback URI. Copy the generated $CLIENT_ID and one-time client secret into $CLIENT_SECRET when it is shown; Backplane will not show it again.",
          "Enable MCP (/mcp), assign matching tool scopes to the client, and grant matching scopes to the signing-in user.",
          "Configure ChatGPT's MCP server URL as #{mcp_url}. Enter $CLIENT_ID and $CLIENT_SECRET in ChatGPT's OAuth settings, then test the connection."
        ],
        examples: [
          %{
            title: "Discover MCP OAuth",
            code:
              "curl -i #{mcp_url}\n# Follow the WWW-Authenticate resource_metadata challenge directly:\ncurl #{mcp_metadata_url}"
          },
          %{
            title: "ChatGPT endpoint values",
            code:
              "MCP_SERVER_URL=#{mcp_url}\nOAUTH_CLIENT_ID=$CLIENT_ID\nOAUTH_CLIENT_SECRET=$CLIENT_SECRET"
          }
        ],
        routes: [
          "POST /mcp",
          "GET /mcp",
          "DELETE /mcp",
          "GET /.well-known/oauth-protected-resource/mcp"
        ]
      },
      %{
        slug: "llm",
        label: "LLM proxy",
        heading: "LLM proxy",
        summary:
          "Authorize API clients for Backplane's separate /v1 resource, then call model endpoints with a resource-bound bearer token.",
        entries: [
          %{
            title: "LLM scopes",
            body:
              "Grant llm::models for model discovery and llm::invoke for inference operations. Request only the scopes the client and user share."
          },
          %{
            title: "Existing credentials remain valid",
            body:
              "Resource OAuth is additive compatibility: existing PAT and legacy bearer access continue under the deployment's configured authentication policy."
          }
        ],
        steps: [
          "Create or select a predefined confidential OAuth client with PKCE S256, enable LLM API (/v1), and assign llm::models and llm::invoke as needed.",
          "Fetch the protected-resource metadata and make an unauthenticated GET request to the canonical /v1 resource to inspect its challenge.",
          "Authorize with resource=#{v1_url}, then exchange $CODE with the same resource value and the original $CODE_VERIFIER.",
          "Send the returned bearer token to /v1 operations and keep provider credentials inside Backplane."
        ],
        examples: [
          %{
            title: "Discover the LLM resource",
            code:
              "curl #{v1_metadata_url}\n# Unauthenticated probe: GET #{v1_url}\ncurl -i #{v1_url}"
          },
          %{
            title: "Authorize with PKCE",
            code:
              "#{authorize_url}?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256&resource=#{v1_url}&scope=llm::models%20llm::invoke"
          },
          %{
            title: "Exchange the authorization code",
            code:
              "curl -X POST #{token_url} \\\n  -u \"$CLIENT_ID:$CLIENT_SECRET\" \\\n  --data-urlencode \"grant_type=authorization_code\" \\\n  --data-urlencode \"code=$CODE\" \\\n  --data-urlencode \"redirect_uri=$REDIRECT_URI\" \\\n  --data-urlencode \"code_verifier=$CODE_VERIFIER\" \\\n  --data-urlencode \"resource=#{v1_url}\""
          },
          %{
            title: "Call the model gateway",
            code: "curl -H \"Authorization: Bearer $ACCESS_TOKEN\" #{v1_url}/models"
          }
        ],
        routes: [
          "GET /v1",
          "GET /v1/models",
          "POST /v1/messages",
          "POST /v1/chat/completions",
          "POST /v1/responses",
          "GET /.well-known/oauth-protected-resource/v1"
        ]
      },
      %{
        slug: "skills",
        label: "Skills library",
        heading: "Skills library",
        summary:
          "Serve, import, export, and browse reusable agent skills through the public Skills API and MCP tools.",
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
          "Use the configured Backplane origin for ChatGPT, Claude Code, and Codex without embedding real credentials.",
        entries: [
          %{
            title: "Keep endpoints distinct",
            body:
              "MCP clients connect to #{mcp_url}; model clients use #{v1_url}. Use separate $MCP_ACCESS_TOKEN and $LLM_ACCESS_TOKEN values because a token for one audience never works on the other."
          }
        ],
        steps: [
          "For ChatGPT, register the exact callback it supplies, select the predefined OAuth client, and configure the MCP endpoint.",
          "For Claude Code, configure the Anthropic-compatible /v1 base URL and add Backplane as an HTTP MCP server.",
          "For Codex, define a Backplane model provider and MCP server, with token values supplied through environment variables."
        ],
        examples: [
          %{
            title: "ChatGPT MCP configuration",
            code:
              "MCP server URL: #{mcp_url}\nOAuth client ID: $CLIENT_ID\nOAuth client secret: $CLIENT_SECRET"
          },
          %{
            title: "Claude Code configuration",
            code:
              "export ANTHROPIC_BASE_URL=\"#{v1_url}\"\nexport ANTHROPIC_API_KEY=\"$LLM_ACCESS_TOKEN\"\nclaude mcp add --transport http --header \"Authorization: Bearer $MCP_ACCESS_TOKEN\" backplane \"#{mcp_url}\""
          },
          %{
            title: "Codex configuration",
            code:
              "export BACKPLANE_LLM_ACCESS_TOKEN=\"$LLM_ACCESS_TOKEN\"\nexport BACKPLANE_MCP_ACCESS_TOKEN=\"$MCP_ACCESS_TOKEN\"\n\n[model_providers.backplane]\nname = \"Backplane\"\nbase_url = \"#{v1_url}\"\nenv_key = \"BACKPLANE_LLM_ACCESS_TOKEN\"\n\n[mcp_servers.backplane]\nurl = \"#{mcp_url}\"\nbearer_token_env_var = \"BACKPLANE_MCP_ACCESS_TOKEN\""
          }
        ],
        routes: ["ChatGPT", "Claude Code", "Codex", "MCP /mcp", "LLM API /v1"]
      },
      %{
        slug: "authentication",
        label: "Authentication",
        heading: "Authentication",
        summary:
          "Manage predefined OAuth clients and troubleshoot the separate MCP and LLM protected resources.",
        entries: [
          %{
            title: "Separate resource audiences",
            body:
              "#{mcp_url} and #{v1_url} are separate OAuth audiences. A token issued for one resource is not valid for the other."
          },
          %{
            title: "Predefined clients and PKCE",
            body:
              "Use predefined OAuth clients. ChatGPT uses a confidential client with its exact registered callback and PKCE S256; the client secret is displayed only once."
          },
          %{
            title: "Refresh and revocation",
            body:
              "A refresh token request that omits resource inherits its original resource, supporting durable ChatGPT connectivity across reconnects. Revoke access at #{revoke_url}."
          },
          %{
            title: "HTTPS and troubleshooting",
            body:
              "OAuth protected resources require HTTPS outside the explicit local development override. invalid_target means the requested resource is missing, repeated, unsupported, or disallowed; invalid_token means the bearer token is invalid or bound to the wrong audience; insufficient_scope means the valid token lacks the required operation scope."
          }
        ],
        steps: [
          "Create a predefined confidential client, keep PKCE S256 enabled, register exact redirect URIs, and assign one or both protected resources.",
          "Assign matching client scopes and user scopes before starting authorization.",
          "Use the same resource during authorization and code exchange. On refresh, omit resource to inherit the original binding or supply that same exact value.",
          "Revoke tokens when access should end, and use the returned OAuth error names to diagnose failed requests."
        ],
        examples: [
          %{
            title: "Protected resource audiences",
            code: "MCP_RESOURCE=#{mcp_url}\nLLM_RESOURCE=#{v1_url}"
          },
          %{
            title: "Revoke a token",
            code:
              "curl -X POST #{revoke_url} \\\n  -u \"$CLIENT_ID:$CLIENT_SECRET\" \\\n  --data-urlencode \"token=$ACCESS_TOKEN\""
          },
          %{
            title: "OAuth error guide",
            code:
              "invalid_target      check the exact resource value\ninvalid_token       obtain a token for the requested audience\ninsufficient_scope request and grant the required scope"
          }
        ],
        routes: [
          "GET /oauth/authorize",
          "POST /oauth/token",
          "POST /oauth/revoke",
          "GET /.well-known/oauth-protected-resource/mcp",
          "GET /.well-known/oauth-protected-resource/v1"
        ]
      }
    ]
  end

  defp join_url(base_url, path) do
    String.trim_trailing(base_url, "/") <> "/" <> String.trim_leading(path, "/")
  end
end
