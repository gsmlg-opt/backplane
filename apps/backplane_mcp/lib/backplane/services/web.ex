defmodule Backplane.Services.Web do
  @moduledoc """
  Unified managed MCP service providing `web::fetch`, `web::search`, and
  `web::x_search`.

  Combines web fetching (HTML→Markdown conversion), multi-backend web search,
  and xAI X Search under a single `web` prefix.
  """

  @behaviour Backplane.Services.ManagedService

  alias Backplane.Services.{WebFetch, WebSearch, WebXSearch}

  @prefix "web"

  @impl true
  def prefix, do: @prefix

  @impl true
  def enabled? do
    Backplane.Settings.get("services.web.enabled") == true
  end

  @impl true
  def tools do
    fetch_tools() ++ search_tools() ++ x_search_tools()
  end

  defp fetch_tools do
    [
      %{
        name: "web::fetch",
        description:
          "Fetches an HTTP(S) URL and converts the content to clean, readable Markdown. Supports optional instructions for targeted extraction.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "format" => "uri",
              "description" => "Full URL to fetch (http or https only)"
            },
            "instructions" => %{
              "type" => "string",
              "description" => "Optional extraction or summarization instruction"
            }
          },
          "required" => ["url"],
          "additionalProperties" => false
        },
        handler: &WebFetch.handle_fetch/1
      }
    ]
  end

  defp search_tools do
    [
      %{
        name: "web::search",
        description:
          "Search the web through Ollama, MiniMax, Z.ai, or BigModel and return normalized results.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Search query"
            },
            "backend" => %{
              "type" => "string",
              "enum" => ~w(ollama minimax z_ai bigmodel),
              "description" => "Search backend. Defaults to the configured service backend."
            },
            "credential" => %{
              "type" => "string",
              "description" => "Optional credentials vault name for the selected backend"
            },
            "max_results" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 10,
              "description" => "Maximum result count, up to 10"
            },
            "search_engine" => %{
              "type" => "string",
              "description" =>
                "Optional search engine for Z.ai/BigModel, for example search_std or search_pro"
            }
          },
          "required" => ["query"],
          "additionalProperties" => false
        },
        handler: &WebSearch.handle_search/1
      }
    ]
  end

  defp x_search_tools do
    [
      %{
        name: "web::x_search",
        description:
          "Search X through xAI Grok's built-in X Search tool. Uses either an xAI API key credential or an xAI Grok OAuth credential.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Search text"
            }
          },
          "required" => ["query"],
          "additionalProperties" => false
        },
        handler: &WebXSearch.handle_x_search/1
      }
    ]
  end
end
