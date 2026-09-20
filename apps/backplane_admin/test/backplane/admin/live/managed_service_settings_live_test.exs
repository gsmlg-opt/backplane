defmodule Backplane.Admin.ManagedServiceSettingsLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Settings
  alias Backplane.Settings.Credentials
  alias Backplane.Services.WebFetch
  alias Backplane.Services.WebSearch

  setup do
    previous_search = Application.get_env(:backplane, :web_search_req_options)
    previous_fetch = Application.get_env(:backplane, :web_fetch_req_options)
    previous_x_search = Application.get_env(:backplane, :web_x_search_req_options)

    Application.put_env(:backplane, :web_search_req_options, plug: {Req.Test, WebSearch})
    Application.put_env(:backplane, :web_fetch_req_options, plug: {Req.Test, WebFetch})

    Application.put_env(:backplane, :web_x_search_req_options,
      plug: {Req.Test, Backplane.Services.WebXSearch}
    )

    Settings.set("services.web_fetch.default_backend", "direct")
    Settings.set("services.web_fetch.firecrawl.base_url", nil)
    Settings.set("services.web_fetch.firecrawl.credential", nil)
    Settings.set("services.web_search.default_backend", "exa")
    Settings.set("services.web_x_search.credential", nil)
    Settings.set("services.web_x_search.model", nil)

    for backend <- ~w(exa tavily ollama minimax) do
      Settings.set("services.web_search.#{backend}.enabled", backend in ~w(exa tavily))
      Settings.set("services.web_search.#{backend}.credential", nil)
      Settings.set("services.web_search.#{backend}.base_url", nil)
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

      if previous_x_search do
        Application.put_env(:backplane, :web_x_search_req_options, previous_x_search)
      else
        Application.delete_env(:backplane, :web_x_search_req_options)
      end
    end)

    :ok
  end

  test "renders fetch and search backend settings without live search", %{conn: conn} do
    {:ok, _credential} = Credentials.store("shared-search-key", "secret", "service")
    {:ok, _xai_credential} = Credentials.store("xai-search-key", "xai-secret", "service")

    {:ok, _view, html} = live(conn, "/mcp/managed/web")

    assert html =~ "Web Settings"
    assert html =~ "Fetch Backend"
    assert html =~ "Firecrawl"
    assert html =~ "Search Backends"
    assert html =~ "Ollama and MiniMax are disabled-by-default backup backends"
    refute html =~ "Live Search"
    assert html =~ "X Search"
    assert html =~ "xAI Credential"
    assert html =~ "Ollama"
    assert html =~ "MiniMax"
    assert html =~ "Exa"
    assert html =~ "Tavily"
    assert html =~ "shared-search-key"
    assert html =~ "xai-search-key"
    refute html =~ "xai-secret"
    refute html =~ ">secret<"
    assert html =~ ~s(href="/system/credentials")
    refute html =~ "Backend API Keys"
    refute html =~ "API Key"
  end

  test "saves fetch and search defaults, toggles, URLs, and vault credentials", %{conn: conn} do
    {:ok, _credential} = Credentials.store("mini-search-key", "mini-secret", "service")
    {:ok, _credential} = Credentials.store("firecrawl-key", "firecrawl-secret", "service")
    {:ok, view, _html} = live(conn, "/mcp/managed/web")

    html =
      view
      |> form("#web-search-settings-form", %{
        "settings" => %{
          "fetch" => %{
            "default_backend" => "firecrawl",
            "firecrawl" => %{
              "base_url" => "https://crawl.example.test/api/",
              "credential" => "firecrawl-key"
            }
          },
          "default_backend" => "minimax",
          "backends" => %{
            "exa" => %{
              "enabled" => "true",
              "credential" => "",
              "base_url" => "https://api.exa.ai"
            },
            "tavily" => %{
              "enabled" => "true",
              "credential" => "",
              "base_url" => "https://api.tavily.com"
            },
            "ollama" => %{
              "credential" => "",
              "base_url" => "https://ollama.com"
            },
            "minimax" => %{
              "enabled" => "true",
              "credential" => "mini-search-key",
              "base_url" => "https://mini.example.test"
            }
          },
          "x_search" => %{
            "credential" => "",
            "model" => ""
          }
        }
      })
      |> render_submit()

    assert html =~ "Web settings saved"
    assert Settings.get("services.web_search.default_backend") == "minimax"
    assert Settings.get("services.web_search.minimax.enabled") == true
    assert Settings.get("services.web_search.minimax.credential") == "mini-search-key"
    assert Settings.get("services.web_search.minimax.base_url") == "https://mini.example.test"
    assert Settings.get("services.web_fetch.default_backend") == "firecrawl"
    assert Settings.get("services.web_fetch.firecrawl.credential") == "firecrawl-key"

    assert Settings.get("services.web_fetch.firecrawl.base_url") ==
             "https://crawl.example.test/api"

    assert has_element?(
             view,
             ~s(input#web-search-base-url-minimax[value="https://mini.example.test"])
           )

    assert has_element?(
             view,
             ~s(input[name="settings[backends][minimax][enabled]"][checked])
           )

    assert {:ok, "mini-secret"} = Credentials.fetch("mini-search-key")
    refute Credentials.exists?("web-search-minimax")
  end

  test "saves xAI X Search credential and model", %{conn: conn} do
    {:ok, _credential} = Credentials.store("xai-search-key", "xai-secret", "service")
    {:ok, view, _html} = live(conn, "/mcp/managed/web")

    html =
      view
      |> form("#web-search-settings-form", %{
        "settings" => %{
          "fetch" => %{
            "default_backend" => "direct",
            "firecrawl" => %{
              "base_url" => "https://api.firecrawl.dev",
              "credential" => ""
            }
          },
          "default_backend" => "exa",
          "backends" => %{
            "exa" => %{
              "enabled" => "true",
              "credential" => "",
              "base_url" => "https://api.exa.ai"
            },
            "tavily" => %{
              "enabled" => "true",
              "credential" => "",
              "base_url" => "https://api.tavily.com"
            },
            "ollama" => %{"credential" => "", "base_url" => "https://ollama.com"},
            "minimax" => %{"credential" => "", "base_url" => "https://api.minimaxi.com"}
          },
          "x_search" => %{
            "credential" => "xai-search-key",
            "model" => "grok-4.3"
          }
        }
      })
      |> render_submit()

    assert html =~ "Web settings saved"
    assert Settings.get("services.web_x_search.credential") == "xai-search-key"
    assert Settings.get("services.web_x_search.model") == "grok-4.3"
  end

  test "validates the full form before writing any settings", %{conn: conn} do
    Settings.set("services.web_search.default_backend", "exa")
    {:ok, view, _html} = live(conn, "/mcp/managed/web")

    html =
      render_submit(view, "save", %{
        "settings" => %{
          "fetch" => %{
            "default_backend" => "firecrawl",
            "firecrawl" => %{"base_url" => "not-a-url", "credential" => "missing"}
          },
          "default_backend" => "tavily",
          "backends" => %{
            "exa" => %{"enabled" => "true", "credential" => "", "base_url" => ""},
            "tavily" => %{"enabled" => "true", "credential" => "", "base_url" => ""},
            "ollama" => %{"credential" => "", "base_url" => ""},
            "minimax" => %{"credential" => "", "base_url" => ""}
          },
          "x_search" => %{
            "credential" => "",
            "model" => ""
          }
        }
      })

    assert html =~ "Firecrawl base URL must be an absolute HTTP(S) URL"
    assert Settings.get("services.web_search.default_backend") == "exa"
    assert Settings.get("services.web_fetch.default_backend") == "direct"
  end

  test "a late invalid credential leaves every submitted setting unchanged", %{conn: conn} do
    Settings.set("services.web_search.default_backend", "exa")
    Settings.set("services.web_fetch.default_backend", "direct")
    {:ok, view, _html} = live(conn, "/mcp/managed/web")

    params =
      valid_web_settings()
      |> put_in(["fetch", "default_backend"], "firecrawl")
      |> put_in(["default_backend"], "tavily")
      |> put_in(["x_search", "credential"], "missing-x-credential")

    html = render_submit(view, "save", %{"settings" => params})

    assert html =~ "xAI X Search credential is not in the credential store"
    assert Settings.get("services.web_search.default_backend") == "exa"
    assert Settings.get("services.web_fetch.default_backend") == "direct"
    assert Settings.get("services.web_search.tavily.base_url") == nil
  end

  test "debug tab calls web::search through the generic tool debugger", %{conn: conn} do
    {:ok, _credential} = Credentials.store("ollama-debug-key", "ollama-secret", "service")
    Settings.set("services.web_search.ollama.credential", "ollama-debug-key")
    Settings.set("services.web_search.ollama.enabled", true)

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

    {:ok, view, html} = live(conn, "/mcp/managed/web?tab=debug")

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

  test "debug tab calls web::x_search through the generic tool debugger", %{conn: conn} do
    {:ok, _credential} = Credentials.store("xai-debug-key", "xai-secret", "service")
    Settings.set("services.web_x_search.credential", "xai-debug-key")

    Req.Test.stub(Backplane.Services.WebXSearch, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path == "/v1/responses"
      assert {"authorization", "Bearer xai-secret"} in conn.req_headers
      assert Jason.decode!(body)["tools"] == [%{"type" => "x_search"}]

      Req.Test.json(conn, %{
        "id" => "resp_debug",
        "model" => "grok-4.3",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "X Search debug result"}]
          }
        ],
        "usage" => %{}
      })
    end)

    {:ok, view, html} = live(conn, "/mcp/managed/web?tab=debug")

    assert html =~ "Web Debug"
    assert html =~ "web::x_search"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{
          "tool_name" => "web::x_search",
          "arguments" =>
            Jason.encode!(%{
              "query" => "latest from xai"
            })
        }
      })
      |> render_submit()

    assert html =~ "Tool Result"
    assert html =~ "X Search debug result"
  end

  test "day debug tab calls selected managed tool", %{conn: conn} do
    {:ok, view, html} = live(conn, "/mcp/managed/day?tab=debug")

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
    assert html =~ "&quot;diff&quot;: 1"
    assert html =~ "&quot;unit&quot;: &quot;day&quot;"
  end

  test "math debug tab calls selected managed tool", %{conn: conn} do
    {:ok, _record} = Backplane.Math.Config.save(%{enabled: true})
    {:ok, view, html} = live(conn, "/mcp/managed/math?tab=debug")

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

    {:ok, view, html} = live(conn, "/mcp/managed/web?tab=debug")

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

  test "Skills debug tab calls an enabled tool", %{conn: conn} do
    previous_setting = :ets.lookup(:backplane_settings, "services.skill.enabled")
    :ets.insert(:backplane_settings, {"services.skill.enabled", true})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "services.skill.enabled")

      if previous_setting != [] do
        :ets.insert(:backplane_settings, previous_setting)
      end
    end)

    {:ok, view, html} = live(conn, "/mcp/managed/skill?tab=debug")

    assert html =~ "Skills Debug"
    assert html =~ "skill::search"
    assert html =~ "skill::list"
    assert html =~ "JSON Argument Schema"

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{"tool_name" => "skill::list", "arguments" => "{}"}
      })
      |> render_submit()

    assert html =~ "Tool Result"
  end

  test "Skills debug tab rejects calls while disabled", %{conn: conn} do
    previous_setting = :ets.lookup(:backplane_settings, "services.skill.enabled")
    :ets.insert(:backplane_settings, {"services.skill.enabled", false})

    on_exit(fn ->
      :ets.delete(:backplane_settings, "services.skill.enabled")

      if previous_setting != [] do
        :ets.insert(:backplane_settings, previous_setting)
      end
    end)

    {:ok, view, _html} = live(conn, "/mcp/managed/skill?tab=debug")

    html =
      view
      |> form("#managed-tool-debug-form", %{
        "debug" => %{"tool_name" => "skill::list", "arguments" => "{}"}
      })
      |> render_submit()

    assert html =~ "Tool Error"
    assert html =~ "Skills service is disabled"
  end

  defp valid_web_settings do
    %{
      "fetch" => %{
        "default_backend" => "direct",
        "firecrawl" => %{
          "base_url" => "https://api.firecrawl.dev",
          "credential" => ""
        }
      },
      "default_backend" => "exa",
      "backends" => %{
        "exa" => %{
          "enabled" => "true",
          "credential" => "",
          "base_url" => "https://api.exa.ai"
        },
        "tavily" => %{
          "enabled" => "true",
          "credential" => "",
          "base_url" => "https://api.tavily.com"
        },
        "ollama" => %{"credential" => "", "base_url" => "https://ollama.com"},
        "minimax" => %{"credential" => "", "base_url" => "https://api.minimaxi.com"}
      },
      "x_search" => %{"credential" => "", "model" => ""}
    }
  end
end
