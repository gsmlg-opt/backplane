defmodule Backplane.AgentRuntime.Codex.Services do
  @moduledoc """
  Explicit opt-in service-backed Codex profile.

  Service calls remain host-configured. A descriptor or adapter cannot grant a
  network destination, search backend, or image-generation credential.
  """

  alias Backplane.AgentRuntime.{Error, Codex.Contract, Codex.Hosted, Codex.Image, Codex.Web}
  alias Backplane.AgentRuntime.ToolCatalog

  @spec definitions() :: [map()]
  def definitions do
    [
      descriptor("web::fetch", "Fetch an authorized HTTP resource", fetch_schema()),
      descriptor("web::search", "Search through an authorized host backend", search_schema()),
      descriptor("web::x_search", "Search an authorized social backend", x_search_schema())
    ]
  end

  @spec contracts(map()) :: [map()]
  def contracts(context) when is_map(context) do
    (definitions() ++ pinned_definitions())
    |> Enum.filter(&configured?(&1.tool_name, context))
    |> Enum.map(fn descriptor ->
      {:ok, {namespace, name}} = Contract.split_name(descriptor.tool_name)

      %{
        namespace: namespace,
        name: name,
        description: descriptor.description,
        schema: descriptor.schema,
        tool_revision: descriptor.tool_revision,
        backend: Backplane.AgentRuntime.Codex.Backend,
        backend_context: %{family: :service, context: context},
        safety: descriptor.safety,
        source: descriptor.source
      }
    end)
  end

  @spec admitted_definitions(map()) :: {:ok, map()} | {:error, Error.t()}
  def admitted_definitions(authority) when is_map(authority) do
    ToolCatalog.admit_batch(definitions(), authority: authority)
  end

  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def call(context, name, arguments)
      when is_map(context) and is_binary(name) and is_map(arguments) do
    case name do
      "web::fetch" -> fetch(context, arguments)
      "web::search" -> search(context, arguments)
      "web::x_search" -> x_search(context, arguments)
      "web::run" -> web_run(context, arguments)
      "image_gen::imagegen" -> image(context, arguments)
      "image::generate" -> image(context, arguments)
      _ -> {:error, Error.new(:not_found, "unknown Codex service", details: %{tool: name})}
    end
  end

  def call(_, _, _),
    do: {:error, Error.new(:validation, "Codex service context and arguments are required")}

  @spec image(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def image(context, arguments) when is_map(context) and is_map(arguments) do
    Image.generate(
      Map.get(context, :image_adapter),
      arguments,
      Map.get(context, :image_options, [])
    )
  end

  @spec hosted_negotiate(module(), [String.t()], map()) :: {:ok, map()} | {:error, Error.t()}
  def hosted_negotiate(adapter, capabilities, context),
    do: Hosted.negotiate(adapter, capabilities, context)

  @spec hosted_invoke(module(), map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def hosted_invoke(adapter, declaration, arguments, context),
    do: Hosted.invoke(adapter, declaration, arguments, context)

  @spec hosted_observe(module(), [map()]) :: {:ok, map()} | {:error, Error.t()}
  def hosted_observe(adapter, events), do: Hosted.observe(adapter, events)

  defp fetch(context, arguments) do
    with {:ok, url} <- required_string(arguments, "url"),
         {:ok, opts} <- web_options(context, arguments) do
      Web.fetch(url, opts)
    end
  end

  defp search(context, arguments) do
    with {:ok, query} <- required_string(arguments, "query"),
         {:ok, adapter} <- required_adapter(context, :search_adapter),
         {:ok, opts} <- web_options(context, arguments) do
      Web.search(adapter, query, opts)
    end
  end

  defp x_search(context, arguments) do
    with {:ok, query} <- required_string(arguments, "query"),
         {:ok, adapter} <- required_adapter(context, :x_search_adapter),
         {:ok, opts} <- web_options(context, arguments) do
      Web.x_search(adapter, query, opts)
    end
  end

  defp web_run(context, arguments) do
    with {:ok, adapter} <- required_adapter(context, :web_run_adapter),
         true <-
           function_exported?(adapter, :run, 2) or unsupported("web::run backend is unavailable"),
         {:ok, opts} <- web_options(context, arguments) do
      case adapter.run(arguments, opts) do
        {:ok, result} when is_map(result) ->
          {:ok, result}

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          {:error,
           Error.new(:malformed_result, "web::run backend returned invalid data",
             details: %{received: other}
           )}
      end
    end
  end

  defp web_options(context, arguments) do
    allowed_hosts =
      Map.get(context, :web_allowed_hosts, Map.get(context, "web_allowed_hosts", []))

    transport = Map.get(context, :web_transport, Map.get(context, "web_transport"))
    timeout = Map.get(arguments, "timeout_ms", Map.get(context, :web_timeout, 5_000))
    result_limit = Map.get(context, :web_result_limit, 1_048_576)

    opts = [allowed_hosts: allowed_hosts, timeout: timeout, result_limit: result_limit]
    opts = if is_nil(transport), do: opts, else: Keyword.put(opts, :transport, transport)
    {:ok, opts}
  end

  defp required_adapter(context, key) do
    case Map.get(context, key, Map.get(context, Atom.to_string(key))) do
      adapter when is_atom(adapter) -> {:ok, adapter}
      _ -> {:error, Error.new(:unsupported_capability, "service backend is unavailable")}
    end
  end

  defp required_string(arguments, key) do
    atom_key = if key == "url", do: :url, else: :query

    case Map.get(arguments, key, Map.get(arguments, atom_key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, Error.new(:validation, "#{key} is required")}
    end
  end

  defp descriptor(name, description, schema) do
    %{
      tool_name: name,
      description: description,
      schema: schema,
      tool_revision: 1,
      backend: __MODULE__,
      safety: %{read_only: true, retry_safe: true, parallel_safe: true},
      source: %{family: :service_backed, profile: :opt_in}
    }
  end

  @doc false
  def execute(_operation),
    do: {:error, Error.new(:unsupported_capability, "service execution requires host context")}

  defp configured?("web::fetch", context) do
    case Map.get(context, :web_allowed_hosts, Map.get(context, "web_allowed_hosts")) do
      :all -> true
      hosts when is_list(hosts) -> hosts != []
      _ -> false
    end
  end

  defp configured?("web::search", context), do: configured_adapter?(context, :search_adapter)
  defp configured?("web::x_search", context), do: configured_adapter?(context, :x_search_adapter)
  defp configured?("web::run", context), do: configured_adapter?(context, :web_run_adapter)

  defp configured?("image_gen::imagegen", context),
    do: configured_adapter?(context, :image_adapter)

  defp configured_adapter?(context, key) do
    case Map.get(context, key, Map.get(context, Atom.to_string(key))) do
      adapter when is_atom(adapter) -> Code.ensure_loaded?(adapter)
      _ -> false
    end
  end

  defp fetch_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["url"],
      "properties" => %{
        "url" => %{"type" => "string", "format" => "uri"},
        "instructions" => %{"type" => "string"}
      }
    }
  end

  defp search_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["query"],
      "properties" => %{"query" => %{"type" => "string", "minLength" => 1}}
    }
  end

  defp x_search_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["query"],
      "properties" => %{"query" => %{"type" => "string", "minLength" => 1}}
    }
  end

  defp pinned_definitions do
    [
      descriptor(
        "web::run",
        "Run web search, open, find, click, or screenshot commands through the configured Codex-compatible search service.",
        web_run_schema()
      ),
      descriptor(
        "image_gen::imagegen",
        "Generate or edit an image through the configured Codex-compatible image service.",
        imagegen_schema()
      )
    ]
  end

  defp web_run_schema do
    query = %{
      "type" => "object",
      "required" => ["q"],
      "properties" => %{
        "q" => %{"type" => "string", "description" => "Search query."},
        "domains" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Whether to filter by a specific list of domains."
        },
        "recency" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Whether to filter by recency, as a number of recent days."
        }
      }
    }

    reference = %{
      "type" => "object",
      "required" => ["ref_id"],
      "properties" => %{
        "ref_id" => %{"type" => "string", "description" => "Reference id or URL to open."},
        "lineno" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Line number to position the page at."
        }
      }
    }

    %{
      "type" => "object",
      "properties" => %{
        "search_query" =>
          array_schema(query, "Query the internet search engine for a given list of queries."),
        "image_query" =>
          array_schema(query, "Query the image search engine for a given list of queries."),
        "open" => array_schema(reference, "Open pages by reference id or URL."),
        "click" => %{
          "type" => "array",
          "description" => "Open links from previously opened pages.",
          "items" =>
            Map.put(reference, "required", ["ref_id", "id"])
            |> put_in(["properties", "id"], %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Numbered link id to open."
            })
        },
        "find" => %{
          "type" => "array",
          "description" => "Find text patterns in pages.",
          "items" =>
            reference
            |> Map.put("required", ["ref_id", "pattern"])
            |> put_in(["properties", "pattern"], %{
              "type" => "string",
              "description" => "Text pattern to find."
            })
        },
        "screenshot" => %{
          "type" => "array",
          "description" => "Take screenshots of PDF pages.",
          "items" =>
            reference
            |> Map.put("required", ["ref_id", "pageno"])
            |> put_in(["properties", "pageno"], %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Zero-indexed PDF page number."
            })
        },
        "finance" =>
          array_schema(
            object_schema(
              %{
                "ticker" => %{"type" => "string", "description" => "Ticker symbol to look up."},
                "type" => %{
                  "type" => "string",
                  "enum" => ["equity", "fund", "crypto", "index"],
                  "description" => "Asset type to look up."
                },
                "market" => %{
                  "type" => "string",
                  "description" =>
                    "ISO 3166-1 alpha-3 country code, OTC, or an empty string for cryptocurrency."
                }
              },
              ["ticker", "type"]
            ),
            "Look up prices for the given stock symbols."
          ),
        "weather" =>
          array_schema(
            object_schema(
              %{
                "location" => %{
                  "type" => "string",
                  "description" => "Location in Country, Area, City format."
                },
                "start" => %{
                  "type" => "string",
                  "description" => "Start date in YYYY-MM-DD format. Defaults to today."
                },
                "duration" => %{
                  "type" => "integer",
                  "minimum" => 0,
                  "description" => "Number of days to return. Defaults to 7."
                }
              },
              ["location"]
            ),
            "Look up weather forecasts."
          ),
        "sports" =>
          array_schema(
            object_schema(
              %{
                "tool" => %{
                  "type" => "string",
                  "enum" => ["sports"],
                  "description" => "Tool name for sports requests."
                },
                "fn" => %{
                  "type" => "string",
                  "enum" => ["schedule", "standings"],
                  "description" => "Sports function to call."
                },
                "league" => %{
                  "type" => "string",
                  "enum" => ["nba", "wnba", "nfl", "nhl", "mlb", "epl", "ncaamb", "ncaawb", "ipl"],
                  "description" => "League to look up."
                },
                "team" => %{
                  "type" => "string",
                  "description" => "Team to look up, using its common broadcast alias."
                },
                "opponent" => %{
                  "type" => "string",
                  "description" => "Opponent to use with team when narrowing the lookup."
                },
                "date_from" => %{
                  "type" => "string",
                  "description" => "Start date in YYYY-MM-DD format."
                },
                "date_to" => %{
                  "type" => "string",
                  "description" => "End date in YYYY-MM-DD format."
                },
                "num_games" => %{
                  "type" => "integer",
                  "minimum" => 0,
                  "description" => "Number of games to return."
                },
                "locale" => %{"type" => "string", "description" => "Locale for the lookup."}
              },
              ["fn", "league"]
            ),
            "Look up sports schedules and standings."
          ),
        "time" =>
          array_schema(
            object_schema(
              %{
                "utc_offset" => %{
                  "type" => "string",
                  "description" => "UTC offset formatted like +03:00."
                }
              },
              ["utc_offset"]
            ),
            "Get time for the given UTC offsets."
          ),
        "response_length" => %{
          "type" => "string",
          "enum" => ["short", "medium", "long"],
          "description" => "Set the length of the response to be returned."
        }
      }
    }
  end

  defp imagegen_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["prompt"],
      "properties" => %{
        "prompt" => %{"type" => "string"},
        "transparent_background" => %{
          "type" => "boolean",
          "default" => false,
          "description" =>
            "Whether the output should have a transparent background. Defaults to false."
        },
        "referenced_image_paths" => %{
          "type" => "array",
          "maxItems" => 5,
          "items" => %{"type" => "string"}
        },
        "num_last_images_to_include" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 5
        }
      }
    }
  end

  defp array_schema(items, description),
    do: %{"type" => "array", "items" => items, "description" => description}

  defp object_schema(properties, required),
    do: %{"type" => "object", "properties" => properties, "required" => required}

  defp unsupported(message), do: {:error, Error.new(:unsupported_capability, message)}
end
