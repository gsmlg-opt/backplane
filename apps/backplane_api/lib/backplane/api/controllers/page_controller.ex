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
      :not_found -> send_resp(conn, 404, dgettext("errors", "not found"))
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

  defp docs_page_title(nil), do: dgettext("common", "Backplane Docs")
  defp docs_page_title(section),
    do: dgettext("common", "%{heading} - Backplane Docs", heading: section.heading)

  defp doc_sections(base_url) do
    mcp_url = join_url(base_url, "/mcp")
    mcp_metadata_url = join_url(base_url, "/.well-known/oauth-protected-resource/mcp")
    v1_url = join_url(base_url, "/v1")
    google_url = join_url(base_url, "/v1beta")
    v1_metadata_url = join_url(base_url, "/.well-known/oauth-protected-resource/v1")
    authorize_url = join_url(base_url, "/oauth/authorize")
    token_url = join_url(base_url, "/oauth/token")
    revoke_url = join_url(base_url, "/oauth/revoke")

    [
      %{
        slug: "mcp",
        label: dgettext("common", "MCP hub"),
        heading: dgettext("common", "MCP hub"),
        summary:
          dgettext("common", "Connect ChatGPT and other MCP clients to Backplane's resource-bound tool gateway."),
        entries: [
          %{
            title: dgettext("common", "One protected MCP resource"),
            body:
              dgettext("common", "%{mcp_url} is the canonical Streamable HTTP endpoint. An unauthenticated request returns a WWW-Authenticate challenge that points to %{mcp_metadata_url}.", mcp_url: mcp_url, mcp_metadata_url: mcp_metadata_url)
          },
          %{
            title: dgettext("common", "Scoped access"),
            body:
              dgettext("common", "Assign the same MCP tool scopes to the predefined client and the signing-in user. Backplane exposes permitted tools with stable prefix::tool names.")
          }
        ],
        steps: [
          dgettext("common", "Copy the exact callback URI shown in the ChatGPT app-management page. It has a shape such as https://chatgpt.com/connector/oauth/<callback_id>. Do not change the callback ID or add a trailing slash."),
          dgettext("common", "Create a predefined confidential Backplane OAuth client, keep PKCE S256 enabled, and register that exact callback URI. Copy the generated $CLIENT_ID and one-time client secret into $CLIENT_SECRET when it is shown; Backplane will not show it again."),
          dgettext("common", "Enable MCP (/mcp), assign matching tool scopes to the client, and grant matching scopes to the signing-in user."),
          dgettext("common", "Configure ChatGPT's MCP server URL as %{mcp_url}. Enter $CLIENT_ID and $CLIENT_SECRET in ChatGPT's OAuth settings, then test the connection.", mcp_url: mcp_url)
        ],
        examples: [
          %{
            title: dgettext("common", "Discover MCP OAuth"),
            code:
              "curl -i #{mcp_url}\n# Follow the WWW-Authenticate resource_metadata challenge directly:\ncurl #{mcp_metadata_url}"
          },
          %{
            title: dgettext("common", "ChatGPT endpoint values"),
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
        label: dgettext("common", "LLM proxy"),
        heading: dgettext("common", "LLM proxy"),
        summary:
          dgettext("common", "Authorize API clients for Backplane's separate /v1 resource, then call model endpoints with a resource-bound bearer token."),
        entries: [
          %{
            title: dgettext("common", "LLM scopes"),
            body:
              dgettext("common", "Grant llm::models for model and audio voice discovery and llm::invoke for inference operations, including speech synthesis. Request only the scopes the client and user share.")
          },
          %{
            title: dgettext("common", "Existing credentials remain valid"),
            body:
              dgettext("common", "Resource OAuth is additive compatibility: existing PAT and legacy bearer access continue under the deployment's configured authentication policy.")
          },
          %{
            title: dgettext("common", "Audio voice discovery (Backplane extension)"),
            body:
              dgettext("common", "GET /v1/audio/voices uses the Backplane bearer token and llm::models scope. This is a Backplane extension, not an official OpenAI list endpoint; OpenAI's POST /v1/audio/voices creates custom voices. Call this GET directly with your HTTP client. Optional model accepts a public speech model alias or provider/model and restricts results to its provider; omit it to list providers with enabled speech bindings, models, and providers.")
          },
          %{
            title: dgettext("common", "Choose a voice for the selected provider"),
            body:
              dgettext("common", "The response is an object=list with data rows containing id, object=audio.voice, name, language (or null), provider, native_id, and type (system or alias), sorted by provider then id. Send the returned id as speech.voice with a model belonging to that provider. Native system voices appear only when allow_native is true; configured aliases appear regardless and override a native voice with the same public id. There is no implicit conversion of OpenAI voices such as alloy.")
          },
          %{
            title: dgettext("common", "Voice catalog and discovery errors"),
            body:
              dgettext("common", "Discovery uses the local MiniMax system-voice snapshot dated 2026-10-06, shared with the admin preview, plus configured voice aliases. It makes no upstream requests, reads no vault secrets, and incurs no provider usage charges; it does not discover account-specific cloned voices or prove credential entitlement or synthesis readiness. Audio disabled returns 503 audio_disabled. An enabled service with no eligible providers or voice policy returns an empty list. Invalid model returns 400 invalid_parameter, unknown or disabled model returns 404 model_not_found, a model for another operation returns 400 operation_mismatch, and an alias loop returns 400 alias_loop.")
          }
        ],
        steps: [
          dgettext("common", "Create or select a predefined confidential OAuth client with PKCE S256, enable LLM API (/v1), and assign llm::models and llm::invoke as needed."),
          dgettext("common", "Fetch the protected-resource metadata and make an unauthenticated GET request to the canonical /v1 resource to inspect its challenge."),
          dgettext("common", "Authorize with resource=%{v1_url}, then exchange $CODE with the same resource value and the original $CODE_VERIFIER.", v1_url: v1_url),
          dgettext("common", "Send the returned bearer token to /v1 operations and keep provider credentials inside Backplane.")
        ],
        examples: [
          %{
            title: dgettext("common", "Discover the LLM resource"),
            code:
              "curl #{v1_metadata_url}\n# Unauthenticated probe: GET #{v1_url}\ncurl -i #{v1_url}"
          },
          %{
            title: dgettext("common", "Authorize with PKCE"),
            code:
              "#{authorize_url}?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256&resource=#{v1_url}&scope=llm::models%20llm::invoke"
          },
          %{
            title: dgettext("common", "Exchange the authorization code"),
            code:
              "curl -X POST #{token_url} \\\n  -u \"$CLIENT_ID:$CLIENT_SECRET\" \\\n  --data-urlencode \"grant_type=authorization_code\" \\\n  --data-urlencode \"code=$CODE\" \\\n  --data-urlencode \"redirect_uri=$REDIRECT_URI\" \\\n  --data-urlencode \"code_verifier=$CODE_VERIFIER\" \\\n  --data-urlencode \"resource=#{v1_url}\""
          },
          %{
            title: dgettext("common", "Call the model gateway"),
            code: "curl -H \"Authorization: Bearer $ACCESS_TOKEN\" #{v1_url}/models"
          },
          %{
            title: dgettext("common", "Discover voices for a speech model"),
            code:
              "curl --get #{v1_url}/audio/voices \\\n  -H \"Authorization: Bearer $ACCESS_TOKEN\" \\\n  --data-urlencode 'model=minimax-audio/speech-2.8-turbo'\n\n# Omit model to discover all eligible speech providers:\ncurl -H \"Authorization: Bearer $ACCESS_TOKEN\" #{v1_url}/audio/voices"
          },
          %{
            title: dgettext("common", "Use a discovered voice ID"),
            code:
              "# Requires llm::invoke; this speech request may incur provider charges.\ncurl #{v1_url}/audio/speech \\\n  -H \"Authorization: Bearer $ACCESS_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d '{\"model\":\"minimax-audio/speech-2.8-turbo\",\"input\":\"Hello from Backplane\",\"voice\":\"female-tianmei\",\"response_format\":\"mp3\"}' \\\n  --output speech.mp3"
          }
        ],
        routes: [
          "GET /v1",
          "GET /v1/models",
          "GET /v1/codex/models",
          "POST /v1/messages",
          "POST /v1/chat/completions",
          "POST /v1/responses",
          "GET /v1/audio/voices (Backplane extension)",
          "POST /v1/audio/speech",
          "POST /v1/audio/transcriptions",
          "GET /.well-known/oauth-protected-resource/v1"
        ]
      },
      %{
        slug: "google",
        label: dgettext("common", "Google GenAI"),
        heading: dgettext("common", "Google GenAI and agy"),
        summary:
          dgettext("common", "Use the native Gemini Developer API through Backplane, or keep the existing Google Antigravity (agy) subscription route explicit and separate."),
        entries: [
          %{
            title: dgettext("common", "Gemini Developer API"),
            body:
              dgettext("common", "The google-gemini-developer provider uses the official Gemini GenerateContent API at /v1beta. Configure an API-key credential in the admin provider settings; Backplane injects it upstream and never forwards caller credentials. Clients may authenticate with Authorization: Bearer, x-api-key, or the Google SDK's x-goog-api-key compatibility header using the same Backplane client token.")
          },
          %{
            title: dgettext("common", "Native Google GenerateContent operations"),
            body:
              dgettext("common", "The native Google surface supports model listing, model details, generateContent, streamGenerateContent with alt=sse, and countTokens. Use the Google-shaped request and response bodies; this route does not silently translate to OpenAI.")
          },
          %{
            title: dgettext("common", "Google Antigravity (agy)"),
            body:
              dgettext("common", "The google-antigravity provider is a separate OAuth subscription surface for the existing agy workflow. It uses its own native Cloud Code protocol and credential; do not reuse a Gemini API key or treat Antigravity as the public Gemini Developer API.")
          }
        ],
        steps: [
          dgettext("common", "In the admin LLM provider page, create Google Gemini Developer API with the google-gemini-developer preset, bind an API-key credential, and confirm the base URL ends in /v1beta."),
          dgettext("common", "Grant the client llm::models and/or llm::invoke, then use the Google resource path under /v1beta with the Backplane bearer token."),
          dgettext("common", "For agy, select the separate google-antigravity preset and its Google OAuth credential. Keep its model aliases and project configuration separate from the Gemini API-key provider.")
        ],
        examples: [
          %{
            title: dgettext("common", "List Google models"),
            code: "curl -H \"Authorization: Bearer $LLM_ACCESS_TOKEN\" #{google_url}/models"
          },
          %{
            title: dgettext("common", "Generate content"),
            code:
              "curl -X POST \\\n  -H \"Authorization: Bearer $LLM_ACCESS_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  #{google_url}/models/gemini-2.5-flash:generateContent \\\n  -d '{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"Hello from Backplane\"}]}]}'"
          },
          %{
            title: dgettext("common", "Stream or count tokens"),
            code:
              "curl -N -X POST #{google_url}/models/gemini-2.5-flash:streamGenerateContent?alt=sse \\\n  -H \"Authorization: Bearer $LLM_ACCESS_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d @request.json\n\ncurl -X POST #{google_url}/models/gemini-2.5-flash:countTokens \\\n  -H \"Authorization: Bearer $LLM_ACCESS_TOKEN\" \\\n  -H \"Content-Type: application/json\" \\\n  -d @request.json"
          },
          %{
            title: dgettext("common", "Google GenAI SDK base URL"),
            code:
              "# Point the SDK at the Backplane origin and pass the Backplane bearer token.\n# The native Google path is /v1beta; do not use /v1/chat/completions.\nBACKPLANE_GOOGLE_BASE_URL=#{base_url}\nBACKPLANE_LLM_ACCESS_TOKEN=$LLM_ACCESS_TOKEN"
          }
        ],
        routes: [
          "GET /v1beta/models",
          "GET /v1beta/models/:model",
          "POST /v1beta/models/:model:generateContent",
          "POST /v1beta/models/:model:streamGenerateContent?alt=sse",
          "POST /v1beta/models/:model:countTokens"
        ]
      },
      %{
        slug: "skills",
        label: dgettext("common", "Skills library"),
        heading: dgettext("common", "Skills library"),
        summary:
          dgettext("common", "Serve, import, export, and browse reusable agent skills through the public Skills API and MCP tools."),
        entries: [
          %{
            title: dgettext("common", "Skill archive routes"),
            body:
              dgettext("common", "Use /skills to list or create records, /skills/export for a bundle, and /skills/:slug/archive for a single archive.")
          },
          %{
            title: dgettext("common", "Managed service tools"),
            body:
              dgettext("common", "The skills managed service exposes skill discovery and retrieval through MCP for connected agents.")
          },
          %{
            title: dgettext("common", "Host-agent support"),
            body:
              dgettext("common", "The host-agent socket can synchronize local skill and memory context with Backplane.")
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
        label: dgettext("common", "Agent setup"),
        heading: dgettext("common", "Agent setup"),
        summary:
          dgettext("common", "Use the configured Backplane origin for ChatGPT, Claude Code, and Codex without embedding real credentials."),
        entries: [
          %{
            title: dgettext("common", "Keep endpoints distinct"),
            body:
              dgettext("common", "MCP clients connect to %{mcp_url}; model clients use %{v1_url}. Resource-bound OAuth access tokens are audience-specific, so use separate $MCP_ACCESS_TOKEN and $LLM_ACCESS_TOKEN values. PAT and legacy credentials follow the configured compatibility policy.", mcp_url: mcp_url, v1_url: v1_url)
          }
        ],
        steps: [
          dgettext("common", "For ChatGPT, register the exact callback it supplies, select the predefined OAuth client, and configure the MCP endpoint."),
          dgettext("common", "For Claude Code, configure the Anthropic-compatible /v1 base URL and add Backplane as an HTTP MCP server."),
          dgettext("common", "For Codex, define a Backplane model provider and MCP server, with token values supplied through environment variables.")
        ],
        examples: [
          %{
            title: dgettext("common", "ChatGPT MCP configuration"),
            code:
              "MCP server URL: #{mcp_url}\nOAuth client ID: $CLIENT_ID\nOAuth client secret: $CLIENT_SECRET"
          },
          %{
            title: dgettext("common", "Claude Code configuration"),
            code:
              "export ANTHROPIC_BASE_URL=\"#{base_url}\"\nexport ANTHROPIC_AUTH_TOKEN=\"$LLM_ACCESS_TOKEN\"\nclaude mcp add --transport http --header \"Authorization: Bearer $MCP_ACCESS_TOKEN\" backplane \"#{mcp_url}\""
          },
          %{
            title: dgettext("common", "Codex configuration"),
            code:
              "# Shell\nexport BACKPLANE_LLM_ACCESS_TOKEN=\"$LLM_ACCESS_TOKEN\"\nexport BACKPLANE_MCP_ACCESS_TOKEN=\"$MCP_ACCESS_TOKEN\"\n\n# ~/.codex/config.toml\n# Replace this placeholder with a model alias exposed by Backplane.\nmodel = \"your-backplane-model-alias\"\nmodel_provider = \"backplane\"\n\n[model_providers.backplane]\nname = \"Backplane\"\nbase_url = \"#{v1_url}\"\nenv_key = \"BACKPLANE_LLM_ACCESS_TOKEN\"\n\n[mcp_servers.backplane]\nurl = \"#{mcp_url}\"\nbearer_token_env_var = \"BACKPLANE_MCP_ACCESS_TOKEN\""
          }
        ],
        routes: ["ChatGPT", "Claude Code", "Codex", "MCP /mcp", "LLM API /v1"]
      },
      %{
        slug: "authentication",
        label: dgettext("common", "Authentication"),
        heading: dgettext("common", "Authentication"),
        summary:
          dgettext("common", "Manage predefined OAuth clients and troubleshoot the separate MCP and LLM protected resources."),
        entries: [
          %{
            title: dgettext("common", "Separate resource audiences"),
            body:
              dgettext("common", "%{mcp_url} and %{v1_url} are separate OAuth audiences. Resource-bound OAuth access tokens are audience-specific: a token issued for one resource is not valid for the other. PAT and legacy credentials follow the configured compatibility policy.", mcp_url: mcp_url, v1_url: v1_url)
          },
          %{
            title: dgettext("common", "Credential header compatibility"),
            body:
              dgettext("common", "All protected API resources accept Authorization: Bearer <token>. x-api-key is an equivalent Backplane client-token alias. Google GenAI clients may also use x-goog-api-key on /v1beta; send only one credential header per request.")
          },
          %{
            title: dgettext("common", "Predefined clients and PKCE"),
            body:
              dgettext("common", "Use predefined OAuth clients. ChatGPT uses a confidential client with its exact registered callback and PKCE S256; the client secret is displayed only once.")
          },
          %{
            title: dgettext("common", "Refresh and revocation"),
            body:
              dgettext("common", "A refresh token request that omits resource inherits its original resource, supporting durable ChatGPT connectivity across reconnects. Revoke access at %{revoke_url}.", revoke_url: revoke_url)
          },
          %{
            title: dgettext("common", "HTTPS and troubleshooting"),
            body:
              dgettext("common", "OAuth protected resources require HTTPS outside the explicit local development override. invalid_target means the requested resource is missing, repeated, unsupported, or disallowed; invalid_token means the bearer token is invalid or bound to the wrong audience; insufficient_scope means the valid token lacks the required operation scope.")
          }
        ],
        steps: [
          dgettext("common", "Create a predefined confidential client, keep PKCE S256 enabled, register exact redirect URIs, and assign one or both protected resources."),
          dgettext("common", "Assign matching client scopes and user scopes before starting authorization."),
          dgettext("common", "Use the same resource during authorization and code exchange. On refresh, omit resource to inherit the original binding or supply that same exact value."),
          dgettext("common", "Revoke tokens when access should end, and use the returned OAuth error names to diagnose failed requests.")
        ],
        examples: [
          %{
            title: dgettext("common", "Protected resource audiences"),
            code: "MCP_RESOURCE=#{mcp_url}\nLLM_RESOURCE=#{v1_url}"
          },
          %{
            title: dgettext("common", "Revoke a token"),
            code:
              "curl -X POST #{revoke_url} \\\n  -u \"$CLIENT_ID:$CLIENT_SECRET\" \\\n  --data-urlencode \"token=$ACCESS_TOKEN\""
          },
          %{
            title: dgettext("common", "OAuth error guide"),
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
