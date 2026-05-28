defmodule BackplaneWeb.ManagedServiceSettingsLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Settings
  alias Backplane.Settings.Credentials
  alias Backplane.Services.WebFetch
  alias Backplane.Services.WebSearch

  setup do
    previous_search = Application.get_env(:backplane, :web_search_req_options)
    previous_fetch = Application.get_env(:backplane, :web_fetch_req_options)

    Application.put_env(:backplane, :web_search_req_options, plug: {Req.Test, WebSearch})
    Application.put_env(:backplane, :web_fetch_req_options, plug: {Req.Test, WebFetch})

    Settings.set("services.web_search.default_backend", "ollama")

    for backend <- ~w(ollama minimax z_ai bigmodel) do
      Settings.set("services.web_search.#{backend}.credential", nil)
    end

    on_exit(fn ->
      if previous_search do
        Application.put_env(:backplane, :web_search_req_options, previous_search)
      else
        Application.delete_env(:backplane, :web_search_req_options)
      end

      if previous_fetch do
        Application.put_env(:backplane, :web_fetch_req_options, previous_fetch)
      else
        Application.delete_env(:backplane, :web_fetch_req_options)
      end
    end)

    :ok
  end

  test "renders web search settings", %{conn: conn} do
    {:ok, _credential} = Credentials.store("shared-search-key", "secret", "service")

    {:ok, _view, html} = live(conn, "/admin/mcp/managed/web")

    assert html =~ "Web Settings"
    assert html =~ "Default Backend"
    assert html =~ "Backend Credentials"
    assert html =~ "Ollama"
    assert html =~ "MiniMax"
    assert html =~ "Z.ai"
    assert html =~ "BigModel"
    assert html =~ "shared-search-key"
    assert html =~ ~s(href="/admin/system/credentials")
    refute html =~ "Backend API Keys"
    refute html =~ "API Key"
  end

  test "saves default backend and selected backend credential", %{conn: conn} do
    {:ok, _credential} = Credentials.store("mini-search-key", "mini-secret", "service")
    {:ok, view, _html} = live(conn, "/admin/mcp/managed/web")

    html =
      view
      |> form("#web-search-settings-form", %{
        "settings" => %{
          "default_backend" => "minimax",
          "credentials" => %{
            "ollama" => "",
            "minimax" => "mini-search-key",
            "z_ai" => "",
            "bigmodel" => ""
          }
        }
      })
      |> render_submit()

    assert html =~ "Web search settings saved"
    assert Settings.get("services.web_search.default_backend") == "minimax"
    assert Settings.get("services.web_search.minimax.credential") == "mini-search-key"
    assert {:ok, "mini-secret"} = Credentials.fetch("mini-search-key")
    refute Credentials.exists?("web-search-minimax")
  end

  test "debug tab calls web::search through the generic tool debugger", %{conn: conn} do
    {:ok, _credential} = Credentials.store("ollama-debug-key", "ollama-secret", "service")
    Settings.set("services.web_search.ollama.credential", "ollama-debug-key")

    Req.Test.stub(WebSearch, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/api/web_search"
      assert {"authorization", "Bearer ollama-secret"} in conn.req_headers

      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Phoenix LiveView",
            "url" => "https://hexdocs.pm/phoenix_live_view",
            "content" => "Rich realtime user experiences"
          }
        ],
        "related_searches" => ["phoenix liveview testing"]
      })
    end)

    {:ok, view, html} = live(conn, "/admin/mcp/managed/web?tab=debug")

    assert html =~ "Web Debug"
    assert html =~ "web::fetch"
    assert html =~ "web::search"
    assert html =~ "JSON Argument Schema"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{
          "tool_name" => "web::search",
          "arguments" =>
            Jason.encode!(%{
              "query" => "phoenix liveview",
              "backend" => "ollama",
              "credential" => "ollama-debug-key",
              "max_results" => 5
            })
        }
      })
      |> render_submit()

    assert html =~ "Tool Result"
    assert html =~ "Phoenix LiveView"
    assert html =~ "https://hexdocs.pm/phoenix_live_view"
    assert html =~ "Rich realtime user experiences"
  end

  test "day debug tab calls selected managed tool", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin/mcp/managed/day?tab=debug")

    assert html =~ "Day Debug"
    assert html =~ "day::diff"
    assert html =~ "JSON Argument Schema"
    assert html =~ "day::now"
    assert html =~ "&quot;timezone&quot;"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{
          "tool_name" => "day::diff",
          "arguments" => Jason.encode!(%{"from" => "", "to" => ""})
        }
      })
      |> render_change()

    assert html =~ "day::diff"
    assert html =~ "&quot;from&quot;"
    assert html =~ "&quot;to&quot;"
    assert html =~ "&quot;required&quot;"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{
          "tool_name" => "day::diff",
          "arguments" =>
            Jason.encode!(%{
              "from" => "2026-05-11T00:00:00Z",
              "to" => "2026-05-12T00:00:00Z",
              "unit" => "day"
            })
        }
      })
      |> render_submit()

    assert html =~ "Tool Result"
    assert html =~ "&quot;diff&quot;: -1"
    assert html =~ "&quot;unit&quot;: &quot;day&quot;"
  end

  test "math debug tab calls selected managed tool", %{conn: conn} do
    {:ok, _record} = Backplane.Math.Config.save(%{enabled: true})
    {:ok, view, html} = live(conn, "/admin/mcp/managed/math?tab=debug")

    assert html =~ "Math Debug"
    assert html =~ "math::evaluate"
    assert html =~ "JSON Argument Schema"
    assert html =~ "&quot;expr&quot;"
    assert html =~ "&quot;ast&quot;"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{
          "tool_name" => "math::evaluate",
          "arguments" => Jason.encode!(%{"expr" => "2 * (3 + 4)"})
        }
      })
      |> render_submit()

    assert html =~ "Tool Result"
    assert html =~ "&quot;value&quot;: 14"
  end

  test "web fetch debug tab calls selected managed tool", %{conn: conn} do
    Req.Test.stub(WebFetch, fn conn ->
      Req.Test.html(conn, """
      <!doctype html>
      <html>
        <head><title>Example Page</title></head>
        <body><main><h1>Hello</h1><p>Readable page.</p></main></body>
      </html>
      """)
    end)

    {:ok, view, html} = live(conn, "/admin/mcp/managed/web?tab=debug")

    assert html =~ "Web Debug"
    assert html =~ "web::fetch"
    assert html =~ "JSON Argument Schema"
    assert html =~ "&quot;url&quot;"
    assert html =~ "&quot;instructions&quot;"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{
          "tool_name" => "web::fetch",
          "arguments" => Jason.encode!(%{"url" => "https://example.test/page"})
        }
      })
      |> render_submit()

    assert html =~ "Tool Result"
    assert html =~ "Example Page"
    assert html =~ "Readable page"
  end
end
