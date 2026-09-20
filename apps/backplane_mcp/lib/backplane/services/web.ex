defmodule Backplane.Services.Web do
  @moduledoc """
  Unified managed MCP service providing `web::fetch`, `web::search`, and
  `web::x_search`.

  Combines web fetching, multi-backend web search, and X search under a single
  `web` prefix.
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
          "Fetches an HTTP(S) URL as Markdown using the configured direct or Firecrawl backend.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "url" => %{
              "type" => "string",
              "format" => "uri",
              "description" => "Full URL to fetch (http or https only)"
            },
            "backend" => %{
              "type" => "string",
              "enum" => ~w(direct firecrawl),
              "description" => "Fetch backend. Defaults to the configured service backend."
            },
            "instructions" => %{
              "type" => "string",
              "description" => "Deprecated compatibility parameter; currently ignored"
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
          "Search with Exa or Tavily advanced controls. Ollama and MiniMax are basic-search backups that must be explicitly enabled.",
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
              "enum" => ~w(exa tavily ollama minimax),
              "description" => "Search backend. Defaults to the configured service backend."
            },
            "credential" => %{
              "type" => "string",
              "description" => "Optional credentials vault name for the selected backend"
            },
            "max_results" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 100,
              "description" => "Maximum results: Exa 100, Tavily 20, Ollama and MiniMax 10"
            },
            "include_domains" => %{
              "type" => "array",
              "items" => %{"type" => "string", "minLength" => 1},
              "description" =>
                "Domains to include. Exa supports 1200; Tavily supports 300; unavailable on backups."
            },
            "exclude_domains" => %{
              "type" => "array",
              "items" => %{"type" => "string", "minLength" => 1},
              "description" =>
                "Domains to exclude. Exa supports 1200; Tavily supports 150; unavailable on backups."
            },
            "include_content" => %{
              "type" => "boolean",
              "default" => false,
              "description" =>
                "Return bounded page content from Exa or Tavily. Backup backends do not support content."
            },
            "max_content_chars" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 10_000,
              "default" => 5_000,
              "description" =>
                "Maximum characters per returned content field when include_content is true. Truncated fields include content_truncated=true."
            },
            "exa" => %{
              "type" => "object",
              "properties" => %{
                "type" => %{
                  "type" => "string",
                  "enum" => ~w(auto instant fast deep-lite deep deep-reasoning),
                  "default" => "auto"
                },
                "category" => %{
                  "type" => "string",
                  "enum" => [
                    "company",
                    "publication",
                    "news",
                    "personal site",
                    "financial report",
                    "people"
                  ]
                },
                "start_published_date" => %{
                  "type" => "string",
                  "format" => "date-time"
                },
                "end_published_date" => %{"type" => "string", "format" => "date-time"},
                "summary" => %{"type" => "boolean", "default" => false},
                "summary_query" => %{"type" => "string", "minLength" => 1},
                "max_age_hours" => %{"type" => "integer", "minimum" => -1, "maximum" => 720}
              },
              "additionalProperties" => false
            },
            "tavily" => %{
              "type" => "object",
              "properties" => %{
                "search_depth" => %{
                  "type" => "string",
                  "enum" => ~w(basic advanced fast ultra-fast),
                  "default" => "basic"
                },
                "topic" => %{
                  "type" => "string",
                  "enum" => ~w(general news finance),
                  "default" => "general"
                },
                "time_range" => %{"type" => "string", "enum" => ~w(day week month year)},
                "start_date" => %{"type" => "string", "format" => "date"},
                "end_date" => %{"type" => "string", "format" => "date"},
                "include_answer" => %{
                  "oneOf" => [
                    %{"type" => "boolean"},
                    %{"type" => "string", "enum" => ~w(basic advanced)}
                  ],
                  "default" => false
                },
                "chunks_per_source" => %{
                  "type" => "integer",
                  "minimum" => 1,
                  "maximum" => 3
                },
                "include_published_date" => %{"type" => "boolean", "default" => false},
                "filter_by_published_date" => %{
                  "type" => "boolean",
                  "default" => false,
                  "description" =>
                    "When true, Tavily excludes undated results while applying date filters."
                }
              },
              "additionalProperties" => false
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
