defmodule Backplane.Services.WebSearchTest do
  use Backplane.DataCase, async: false

  alias Backplane.Services.WebSearch
  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :web_search_req_options)
    Application.put_env(:backplane, :web_search_req_options, plug: {Req.Test, WebSearch})

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_search_req_options, previous)
      else
        Application.delete_env(:backplane, :web_search_req_options)
      end
    end)

    :ok
  end

  test "tools/0 emits web_search::search with ManagedService-shaped fields" do
    [tool] = WebSearch.tools()

    assert tool.name == "web_search::search"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert is_function(tool.handler, 1)
  end

  test "handle_search/1 searches Ollama and normalizes results" do
    {:ok, _} = Credentials.store("ollama-search", "ollama-secret", "service")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/api/web_search"
      assert {"authorization", "Bearer ollama-secret"} in conn.req_headers
      assert %{"query" => "elixir mcp", "max_results" => 3} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Elixir MCP",
            "url" => "https://example.test/elixir-mcp",
            "content" => "MCP servers in Elixir"
          }
        ]
      })
    end)

    assert {:ok, result} =
             WebSearch.handle_search(%{
               "query" => "elixir mcp",
               "backend" => "ollama",
               "credential" => "ollama-search",
               "max_results" => 3
             })

    assert result["backend"] == "ollama"
    assert result["query"] == "elixir mcp"

    assert [
             %{
               "title" => "Elixir MCP",
               "url" => "https://example.test/elixir-mcp",
               "snippet" => "MCP servers in Elixir"
             }
           ] = result["results"]
  end

  test "handle_search/1 searches MiniMax coding plan search and normalizes results" do
    {:ok, _} = Credentials.store("minimax-search", "minimax-secret", "service")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/v1/coding_plan/search"
      assert {"authorization", "Bearer minimax-secret"} in conn.req_headers
      assert %{"q" => "phoenix liveview"} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "organic_results" => [
          %{
            "title" => "LiveView",
            "link" => "https://example.test/liveview",
            "snippet" => "Phoenix LiveView docs"
          }
        ],
        "related_searches" => ["phoenix liveview testing"]
      })
    end)

    assert {:ok, result} =
             WebSearch.handle_search(%{
               "query" => "phoenix liveview",
               "backend" => "minimax",
               "credential" => "minimax-search"
             })

    assert result["backend"] == "minimax"

    assert [
             %{
               "title" => "LiveView",
               "url" => "https://example.test/liveview",
               "snippet" => "Phoenix LiveView docs"
             }
           ] = result["results"]

    assert result["related_searches"] == ["phoenix liveview testing"]
  end

  test "handle_search/1 searches Z.ai-compatible web search APIs" do
    {:ok, _} = Credentials.store("zai-search", "zai-secret", "service")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/api/paas/v4/web_search"
      assert {"authorization", "Bearer zai-secret"} in conn.req_headers

      assert %{
               "search_engine" => "search_std",
               "search_query" => "zai search",
               "count" => 2
             } = Jason.decode!(body)

      Req.Test.json(conn, %{
        "search_result" => [
          %{
            "title" => "Z.ai Search",
            "link" => "https://example.test/zai",
            "content" => "Z.ai web search result"
          }
        ]
      })
    end)

    assert {:ok, result} =
             WebSearch.handle_search(%{
               "query" => "zai search",
               "backend" => "z_ai",
               "credential" => "zai-search",
               "max_results" => 2,
               "search_engine" => "search_std"
             })

    assert result["backend"] == "z_ai"

    assert [
             %{
               "title" => "Z.ai Search",
               "url" => "https://example.test/zai",
               "snippet" => "Z.ai web search result"
             }
           ] = result["results"]
  end

  test "handle_search/1 requires a configured credential" do
    assert {:error, %{code: "web_search_error", message: message}} =
             WebSearch.handle_search(%{
               "query" => "missing credential",
               "backend" => "ollama"
             })

    assert message =~ "credential"
  end
end
