defmodule Backplane.Services.WebSearchTest do
  use BackplaneMcp.DataCase, async: false

  alias Backplane.Services.{Web, WebSearch}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  @backends ~w(exa tavily ollama minimax)

  setup do
    previous = Application.get_env(:backplane, :web_search_req_options)
    Application.put_env(:backplane, :web_search_req_options, plug: {Req.Test, WebSearch})
    Settings.set("services.web.enabled", true)
    Settings.set("services.web_search.default_backend", nil)

    for backend <- @backends do
      Settings.set("services.web_search.#{backend}.credential", nil)
      Settings.set("services.web_search.#{backend}.base_url", nil)
      Settings.set("services.web_search.#{backend}.enabled", backend in ~w(exa tavily))
    end

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_search_req_options, previous)
      else
        Application.delete_env(:backplane, :web_search_req_options)
      end
    end)

    :ok
  end

  test "web::search exposes all supported backends and defaults to Exa" do
    tool = Enum.find(Web.tools(), &(&1.name == "web::search"))
    assert get_in(tool.input_schema, ["properties", "backend", "enum"]) == @backends
    assert get_in(tool.input_schema, ["properties", "max_results", "maximum"]) == 100
    assert get_in(tool.input_schema, ["properties", "exa", "additionalProperties"]) == false
    assert get_in(tool.input_schema, ["properties", "tavily", "additionalProperties"]) == false

    assert {:error, %{message: message}} = WebSearch.handle_search(%{"query" => "elixir"})
    assert message == "exa web search credential is not configured"
  end

  test "missing enable settings default Exa and Tavily on, Ollama and MiniMax off" do
    for backend <- @backends do
      Settings.set("services.web_search.#{backend}.enabled", nil)
    end

    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    {:ok, _} = Credentials.store("tavily-key", "tavily-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")
    Settings.set("services.web_search.tavily.credential", "tavily-key")

    Req.Test.stub(WebSearch, fn conn -> Req.Test.json(conn, %{"results" => []}) end)

    assert {:ok, %{"backend" => "exa"}} = WebSearch.handle_search(%{"query" => "elixir"})

    assert {:ok, %{"backend" => "tavily"}} =
             WebSearch.handle_search(%{"query" => "elixir", "backend" => "tavily"})

    for backend <- ~w(ollama minimax) do
      assert {:error, %{message: message}} =
               WebSearch.handle_search(%{"query" => "elixir", "backend" => backend})

      assert message == "#{backend} web search backend is disabled"
    end
  end

  test "searches Exa with advanced options and normalizes bounded rich results" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.host == "api.exa.ai"
      assert conn.request_path == "/search"
      assert {"x-api-key", "exa-secret"} in conn.req_headers

      assert Jason.decode!(body) == %{
               "query" => "elixir mcp",
               "numResults" => 3,
               "includeDomains" => ["hexdocs.pm"],
               "excludeDomains" => ["example.com"],
               "type" => "deep",
               "category" => "publication",
               "startPublishedDate" => "2026-01-01T00:00:00Z",
               "endPublishedDate" => "2026-09-20T00:00:00Z",
               "contents" => %{
                 "highlights" => %{"maxCharacters" => 1500},
                 "text" => %{"maxCharacters" => 20},
                 "summary" => %{"query" => "focus on MCP"},
                 "maxAgeHours" => 24
               }
             }

      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Elixir MCP",
            "url" => "https://example.test/elixir",
            "text" => "MCP servers in Elixir with more text",
            "highlights" => ["MCP servers in Elixir"],
            "summary" => "A summary",
            "score" => 0,
            "author" => "José",
            "publishedDate" => "2026-09-20"
          }
        ],
        "requestId" => "exa_req",
        "resolvedSearchType" => "deep",
        "costDollars" => %{
          "total" => 0.01,
          "search" => %{"neural" => 0.007},
          "contents" => %{"text" => 0.001, "highlights" => 0, "summary" => 0.002},
          "summary" => 0.002
        }
      })
    end)

    assert {:ok, result} =
             WebSearch.handle_search(%{
               "query" => "elixir mcp",
               "max_results" => 3,
               "include_domains" => ["hexdocs.pm"],
               "exclude_domains" => ["example.com"],
               "include_content" => true,
               "max_content_chars" => 20,
               "exa" => %{
                 "type" => "deep",
                 "category" => "publication",
                 "start_published_date" => "2026-01-01T00:00:00Z",
                 "end_published_date" => "2026-09-20T00:00:00Z",
                 "summary" => true,
                 "summary_query" => "focus on MCP",
                 "max_age_hours" => 24
               }
             })

    assert result["backend"] == "exa"

    assert result["results"] == [
             %{
               "title" => "Elixir MCP",
               "url" => "https://example.test/elixir",
               "snippet" => "MCP servers in Elixir",
               "content" => "MCP servers in Elixi",
               "content_truncated" => true,
               "highlights" => ["MCP servers in Elixir"],
               "summary" => "A summary",
               "score" => 0,
               "author" => "José",
               "published_at" => "2026-09-20"
             }
           ]

    assert result["request_id"] == "exa_req"
    assert result["resolved_search_type"] == "deep"

    assert result["cost_dollars"] == %{
             "total" => 0.01,
             "search" => %{"neural" => 0.007},
             "contents" => %{"text" => 0.001, "highlights" => 0, "summary" => 0.002},
             "summary" => 0.002
           }
  end

  test "searches Tavily with advanced options and normalizes metadata" do
    {:ok, _} = Credentials.store("tavily-key", "tavily-secret", "service")
    Settings.set("services.web_search.tavily.credential", "tavily-key")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert conn.host == "api.tavily.com"
      assert conn.request_path == "/search"
      assert {"authorization", "Bearer tavily-secret"} in conn.req_headers

      assert Jason.decode!(body) == %{
               "query" => "phoenix",
               "max_results" => 2,
               "include_domains" => ["phoenixframework.org"],
               "exclude_domains" => [],
               "include_raw_content" => "markdown",
               "search_depth" => "advanced",
               "topic" => "news",
               "start_date" => "2026-09-01",
               "end_date" => "2026-09-20",
               "include_answer" => "advanced",
               "chunks_per_source" => 3,
               "include_published_date" => true,
               "filter_by_published_date" => true,
               "include_usage" => true
             }

      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Phoenix",
            "url" => "https://phoenixframework.org",
            "content" => "Productive web framework",
            "raw_content" => "Full page",
            "score" => 0,
            "published_date" => "2026-09-19"
          }
        ],
        "answer" => "Phoenix is an Elixir framework.",
        "request_id" => "tvly_req",
        "response_time" => 1.25,
        "usage" => %{"credits" => 2}
      })
    end)

    assert {:ok, result} =
             WebSearch.handle_search(%{
               "query" => "phoenix",
               "backend" => "tavily",
               "max_results" => 2,
               "include_domains" => ["phoenixframework.org"],
               "include_content" => true,
               "tavily" => %{
                 "search_depth" => "advanced",
                 "topic" => "news",
                 "start_date" => "2026-09-01",
                 "end_date" => "2026-09-20",
                 "include_answer" => "advanced",
                 "chunks_per_source" => 3,
                 "include_published_date" => true,
                 "filter_by_published_date" => true
               }
             })

    assert result["results"] == [
             %{
               "title" => "Phoenix",
               "url" => "https://phoenixframework.org",
               "snippet" => "Productive web framework",
               "content" => "Full page",
               "score" => 0,
               "published_at" => "2026-09-19"
             }
           ]

    assert result["answer"] == "Phoenix is an Elixir framework."
    assert result["request_id"] == "tvly_req"
    assert result["response_time_seconds"] == 1.25
    assert result["usage"] == %{"credits" => 2}
  end

  test "validates provider limits, strict fields, and provider ownership before HTTP" do
    cases = [
      {%{"query" => "q", "max_results" => 101}, "max_results must be between 1 and 100 for exa"},
      {%{"query" => "q", "backend" => "tavily", "max_results" => 21},
       "max_results must be between 1 and 20 for tavily"},
      {%{"query" => "q", "backend" => "ollama", "max_results" => 11},
       "max_results must be between 1 and 10 for ollama"},
      {%{"query" => "q", "backend" => nil}, "unsupported web search backend"},
      {%{"query" => "q", "credential" => nil}, "credential must be a nonblank string"},
      {%{"query" => "q", "unknown" => true}, "unknown web search option: unknown"},
      {%{"query" => "q", "exa" => %{"unknown" => true}}, "unknown exa option: unknown"},
      {%{"query" => "q", "tavily" => %{"topic" => "news"}},
       "tavily options are only supported by the tavily backend"},
      {%{"query" => "q", "include_domains" => [""]},
       "include_domains must contain nonblank strings"}
    ]

    for {params, expected} <- cases do
      assert {:error, %{message: ^expected}} = WebSearch.handle_search(params)
    end
  end

  test "minimal Exa and Tavily calls request bounded snippets without page content" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    {:ok, _} = Credentials.store("tavily-key", "tavily-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")
    Settings.set("services.web_search.tavily.credential", "tavily-key")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.host do
        "api.exa.ai" ->
          assert Jason.decode!(body) == %{
                   "query" => "exa query",
                   "numResults" => 5,
                   "type" => "auto",
                   "contents" => %{
                     "highlights" => %{"maxCharacters" => 1500},
                     "text" => false
                   }
                 }

        "api.tavily.com" ->
          assert Jason.decode!(body) == %{
                   "query" => "tavily query",
                   "max_results" => 5,
                   "include_domains" => [],
                   "exclude_domains" => [],
                   "include_raw_content" => false,
                   "search_depth" => "basic",
                   "topic" => "general",
                   "include_answer" => false,
                   "include_published_date" => false,
                   "filter_by_published_date" => false,
                   "include_usage" => true
                 }
      end

      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:ok, %{"backend" => "exa"}} =
             WebSearch.handle_search(%{"query" => "exa query"})

    assert {:ok, %{"backend" => "tavily"}} =
             WebSearch.handle_search(%{"query" => "tavily query", "backend" => "tavily"})
  end

  test "Exa company search omits unsupported empty domain and publication filters" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["category"] == "company"
      refute Map.has_key?(payload, "includeDomains")
      refute Map.has_key?(payload, "excludeDomains")
      refute Map.has_key?(payload, "startPublishedDate")
      refute Map.has_key?(payload, "endPublishedDate")

      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:ok, _result} =
             WebSearch.handle_search(%{"query" => "Acme", "exa" => %{"category" => "company"}})
  end

  test "validates dates and incompatible provider combinations" do
    cases = [
      {%{"query" => "q", "exa" => %{"start_published_date" => "2026-02-30T00:00:00Z"}},
       "exa.start_published_date must be an ISO8601 datetime"},
      {%{
         "query" => "q",
         "exa" => %{
           "start_published_date" => "2026-09-20T00:00:00Z",
           "end_published_date" => "2026-09-01T00:00:00Z"
         }
       }, "exa.start_published_date must not be after exa.end_published_date"},
      {%{
         "query" => "q",
         "backend" => "tavily",
         "tavily" => %{"time_range" => "week", "start_date" => "2026-09-01"}
       }, "tavily.time_range cannot be combined with explicit dates"},
      {%{
         "query" => "q",
         "backend" => "tavily",
         "tavily" => %{"search_depth" => "ultra-fast", "chunks_per_source" => 2}
       }, "tavily.chunks_per_source is not supported with ultra-fast search_depth"},
      {%{
         "query" => "q",
         "exa" => %{"category" => "company", "start_published_date" => "2026-09-01T00:00:00Z"}
       }, "exa category company does not support published date filters"}
    ]

    for {params, expected} <- cases do
      assert {:error, %{message: ^expected}} = WebSearch.handle_search(params)
    end
  end

  test "legacy backends reject advanced features instead of silently dropping them" do
    Settings.set("services.web_search.ollama.enabled", true)

    for {extra, expected} <- [
          {%{"include_content" => true}, "include_content is not supported by ollama"},
          {%{"include_domains" => ["example.com"]}, "domain filters are not supported by ollama"},
          {%{"exa" => %{"type" => "fast"}}, "exa options are only supported by the exa backend"}
        ] do
      params = Map.merge(%{"query" => "q", "backend" => "ollama"}, extra)
      assert {:error, %{message: ^expected}} = WebSearch.handle_search(params)
    end
  end

  test "bounds snippets for legacy results and marks truncation" do
    {:ok, _} = Credentials.store("ollama-key", "ollama-secret", "service")
    Settings.set("services.web_search.ollama.enabled", true)

    Req.Test.stub(WebSearch, fn conn ->
      Req.Test.json(conn, %{
        "results" => [
          %{"url" => "https://example.test", "content" => String.duplicate("a", 1600)}
        ]
      })
    end)

    assert {:ok, %{"results" => [result]}} =
             WebSearch.handle_search(%{
               "query" => "q",
               "backend" => "ollama",
               "credential" => "ollama-key"
             })

    assert String.length(result["snippet"]) == 1500
    assert result["snippet_truncated"] == true
  end

  test "disabled backend rejects explicit backend and credential overrides" do
    {:ok, _} = Credentials.store("ollama-key", "ollama-secret", "service")

    assert {:error, %{message: message}} =
             WebSearch.handle_search(%{
               "query" => "elixir",
               "backend" => "ollama",
               "credential" => "ollama-key"
             })

    assert message == "ollama web search backend is disabled"
  end

  test "legacy configured default remains disabled until explicitly enabled" do
    {:ok, _} = Credentials.store("minimax-key", "minimax-secret", "service")
    Settings.set("services.web_search.default_backend", "minimax")
    Settings.set("services.web_search.minimax.credential", "minimax-key")

    assert {:error, %{message: "minimax web search backend is disabled"}} =
             WebSearch.handle_search(%{"query" => "elixir"})
  end

  test "enabled Ollama and MiniMax backends retain their request contracts" do
    {:ok, _} = Credentials.store("ollama-key", "ollama-secret", "service")
    {:ok, _} = Credentials.store("minimax-key", "minimax-secret", "service")
    Settings.set("services.web_search.ollama.enabled", true)
    Settings.set("services.web_search.minimax.enabled", true)

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/api/web_search" ->
          assert {"authorization", "Bearer ollama-secret"} in conn.req_headers
          assert Jason.decode!(body) == %{"query" => "ollama query", "max_results" => 2}
          Req.Test.json(conn, %{"results" => []})

        "/v1/coding_plan/search" ->
          assert {"authorization", "Bearer minimax-secret"} in conn.req_headers
          assert {"mm-api-source", "Minimax-MCP"} in conn.req_headers
          assert Jason.decode!(body) == %{"q" => "minimax query"}
          Req.Test.json(conn, %{"organic" => []})
      end
    end)

    assert {:ok, %{"backend" => "ollama"}} =
             WebSearch.handle_search(%{
               "query" => "ollama query",
               "backend" => "ollama",
               "credential" => "ollama-key",
               "max_results" => 2
             })

    assert {:ok, %{"backend" => "minimax"}} =
             WebSearch.handle_search(%{
               "query" => "minimax query",
               "backend" => "minimax",
               "credential" => "minimax-key"
             })
  end

  test "does not fall back when the selected provider fails" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    {:ok, _} = Credentials.store("tavily-key", "tavily-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")
    Settings.set("services.web_search.tavily.credential", "tavily-key")

    test_pid = self()

    Req.Test.stub(WebSearch, fn conn ->
      send(test_pid, {:searched, conn.host})
      Plug.Conn.send_resp(conn, 503, ~s({"error":"unavailable"}))
    end)

    assert {:error, %{message: message}} = WebSearch.handle_search(%{"query" => "elixir"})
    assert message =~ "HTTP 503"
    assert_receive {:searched, "api.exa.ai"}
    refute_receive {:searched, "api.tavily.com"}
  end

  test "rejects malformed successful payload and global disable" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")

    Req.Test.stub(WebSearch, fn conn -> Req.Test.json(conn, %{"requestId" => "req_1"}) end)

    assert {:error, %{message: "Exa returned a malformed response"}} =
             WebSearch.handle_search(%{"query" => "elixir"})

    Settings.set("services.web.enabled", false)

    assert {:error, %{message: "web::search is disabled"}} =
             WebSearch.handle_search(%{"query" => "elixir"})
  end

  test "provider errors cannot echo credentials" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")

    Req.Test.stub(WebSearch, fn conn ->
      Req.Test.json(conn, %{"error" => "invalid credential exa-secret"})
    end)

    assert {:error, %{message: message}} = WebSearch.handle_search(%{"query" => "elixir"})
    assert message == "Exa API request failed"
    refute message =~ "exa-secret"
  end

  test "Exa and Tavily reject malformed nested result entries" do
    for {backend, credential} <- [{"exa", "exa-key"}, {"tavily", "tavily-key"}] do
      {:ok, _} = Credentials.store(credential, "#{backend}-secret", "service")
      Settings.set("services.web_search.#{backend}.credential", credential)

      Req.Test.stub(WebSearch, fn conn ->
        Req.Test.json(conn, %{
          "results" => [nil, 42, %{}, %{"title" => "Missing URL"}]
        })
      end)

      assert {:error, %{message: message}} =
               WebSearch.handle_search(%{"query" => "elixir", "backend" => backend})

      assert message == "#{String.capitalize(backend)} returned a malformed response"
    end
  end

  test "Exa and Tavily reject nested provider errors even when results are present" do
    for {backend, credential} <- [{"exa", "exa-key"}, {"tavily", "tavily-key"}] do
      {:ok, _} = Credentials.store(credential, "#{backend}-secret", "service")
      Settings.set("services.web_search.#{backend}.credential", credential)

      Req.Test.stub(WebSearch, fn conn ->
        Req.Test.json(conn, %{
          "error" => %{"message" => "invalid #{backend}-secret"},
          "results" => [%{"title" => "Fake", "url" => "https://example.test"}]
        })
      end)

      assert {:error, %{message: message}} =
               WebSearch.handle_search(%{"query" => "elixir", "backend" => backend})

      assert message == "#{String.capitalize(backend)} API request failed"
      refute message =~ "#{backend}-secret"
    end
  end

  test "rejects malformed provider metadata instead of returning raw values" do
    {:ok, _} = Credentials.store("exa-key", "exa-secret", "service")
    Settings.set("services.web_search.exa.credential", "exa-key")

    Req.Test.stub(WebSearch, fn conn ->
      Req.Test.json(conn, %{"results" => [], "costDollars" => 0.01})
    end)

    assert {:error, %{message: "Exa returned a malformed response"}} =
             WebSearch.handle_search(%{"query" => "elixir"})
  end
end
