defmodule Backplane.Services.WebSearchTest do
  use Backplane.DataCase, async: false

  alias Backplane.Services.{Web, WebSearch}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :web_search_req_options)
    Application.put_env(:backplane, :web_search_req_options, plug: {Req.Test, WebSearch})
    Settings.set("services.web_search.minimax.base_url", nil)

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :web_search_req_options, previous)
      else
        Application.delete_env(:backplane, :web_search_req_options)
      end
    end)

    :ok
  end

  test "web::search tool exposes only supported web search backends" do
    tool = Enum.find(Web.tools(), &(&1.name == "web::search"))

    assert tool.name == "web::search"
    assert is_binary(tool.description)
    assert is_map(tool.input_schema)
    assert is_function(tool.handler, 1)
    assert get_in(tool.input_schema, ["properties", "backend", "enum"]) == ~w(ollama minimax)
    refute Map.has_key?(tool.input_schema["properties"], "search_engine")
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

  test "handle_search/1 decodes JSON string responses before normalizing" do
    {:ok, _} = Credentials.store("ollama-search", "ollama-secret", "service")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "results" => [
            %{
              "title" => "OpenAI",
              "url" => "https://openai.com/",
              "content" => "OpenAI research and products"
            }
          ]
        })
      )
    end)

    assert {:ok, result} =
             WebSearch.handle_search(%{
               "query" => "openai",
               "backend" => "ollama",
               "credential" => "ollama-search",
               "max_results" => 1
             })

    assert [
             %{
               "title" => "OpenAI",
               "url" => "https://openai.com/",
               "snippet" => "OpenAI research and products"
             }
           ] = result["results"]
  end

  test "handle_search/1 searches MiniMax coding plan search and normalizes results" do
    {:ok, _} = Credentials.store("minimax-search", "minimax-secret", "service")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.host == "api.minimaxi.com"
      assert conn.request_path == "/v1/coding_plan/search"
      assert {"authorization", "Bearer minimax-secret"} in conn.req_headers
      assert {"mm-api-source", "Minimax-MCP"} in conn.req_headers
      assert %{"q" => "phoenix liveview"} = Jason.decode!(body)

      Req.Test.json(conn, %{
        "organic" => [
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

  test "handle_search/1 reports MiniMax response errors" do
    {:ok, _} = Credentials.store("minimax-search", "minimax-secret", "service")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      Req.Test.json(conn, %{
        "base_resp" => %{
          "status_code" => 2049,
          "status_msg" => "invalid api key"
        }
      })
    end)

    assert {:error, %{code: "web_search_error", message: message}} =
             WebSearch.handle_search(%{
               "query" => "phoenix liveview",
               "backend" => "minimax",
               "credential" => "minimax-search"
             })

    assert message == "MiniMax API error 2049: invalid api key"
  end

  test "handle_search/1 rejects removed web search backends" do
    {:ok, _} = Credentials.store("removed-search", "removed-secret", "service")

    for backend <- ~w(z_ai bigmodel) do
      assert {:error, %{code: "web_search_error", message: message}} =
               WebSearch.handle_search(%{
                 "query" => "#{backend} search",
                 "backend" => backend,
                 "credential" => "removed-search"
               })

      assert message == "unsupported web search backend: #{backend}"
    end
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
