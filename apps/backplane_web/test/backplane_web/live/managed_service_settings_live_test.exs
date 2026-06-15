defmodule BackplaneWeb.ManagedServiceSettingsLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
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

    Settings.set("services.web_search.default_backend", "ollama")
    Settings.set("services.web_live_search.models", [])
    Settings.set("services.web_live_search.model", nil)
    Settings.set("services.web_x_search.credential", nil)
    Settings.set("services.web_x_search.model", nil)

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

      if previous_x_search do
        Application.put_env(:backplane, :web_x_search_req_options, previous_x_search)
      else
        Application.delete_env(:backplane, :web_x_search_req_options)
      end
    end)

    :ok
  end

  test "renders web search settings", %{conn: conn} do
    {:ok, _credential} = Credentials.store("shared-search-key", "secret", "service")
    {:ok, _xai_credential} = Credentials.store("xai-search-key", "xai-secret", "service")

    {:ok, _view, html} = live(conn, "/admin/mcp/managed/web")

    assert html =~ "Web Settings"
    assert html =~ "Default Backend"
    assert html =~ "Backend Credentials"
    assert html =~ "Live Search"
    assert html =~ "X Search"
    assert html =~ "xAI Credential"
    assert html =~ "Ollama"
    assert html =~ "MiniMax"
    assert html =~ "Z.ai"
    assert html =~ "BigModel"
    assert html =~ "shared-search-key"
    assert html =~ "xai-search-key"
    assert html =~ ~s(href="/admin/system/credentials")
    refute html =~ "Backend API Keys"
    refute html =~ "API Key"
  end

  test "renders only supported live search model options", %{conn: conn} do
    create_model_surface("openai-live", "gpt-5.5", :openai,
      preset_key: "openai",
      base_url: "https://api.openai.com/v1"
    )

    create_model_surface("xai-live", "grok-4.3", :openai,
      preset_key: "x-ai",
      base_url: "https://api.x.ai/v1"
    )

    create_model_surface("openrouter-live", "gpt-4o", :openai,
      preset_key: "openrouter",
      base_url: "https://openrouter.ai/api/v1"
    )

    create_model_surface("anthropic-live", "claude-sonnet-5", :anthropic)
    create_model_surface("disabled-live", "disabled-model", :openai, surface_enabled: false)

    Settings.set("services.web_live_search.models", ["openai-live/gpt-5.5"])

    {:ok, view, html} = live(conn, "/admin/mcp/managed/web")

    assert html =~ "Live Search"
    assert html =~ "openai-live/gpt-5.5"
    assert html =~ "xai-live/grok-4.3"
    refute html =~ "openrouter-live/gpt-4o"
    refute html =~ "anthropic-live/claude-sonnet-5"
    refute html =~ "disabled-live/disabled-model"

    assert has_element?(
             view,
             ~s(input[name="settings[live_search][models][]"][value="openai-live/gpt-5.5"][checked])
           )

    assert has_element?(
             view,
             ~s(input[name="settings[live_search][models][]"][value="xai-live/grok-4.3"])
           )
  end

  test "renders default live search model options for supported providers without discovered models",
       %{conn: conn} do
    create_provider_api("openai-codex", "openai-codex", "https://chatgpt.com/backend-api/codex")
    create_provider_api("x-ai", "x-ai", "https://api.x.ai/v1")

    {:ok, _view, html} = live(conn, "/admin/mcp/managed/web")

    assert html =~ "openai-codex/gpt-5.5"
    assert html =~ "x-ai/grok-4.3"
    refute html =~ "No supported OpenAI-compatible models are enabled."
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
          },
          "x_search" => %{
            "credential" => "",
            "model" => ""
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

  test "saves xAI X Search credential and model", %{conn: conn} do
    {:ok, _credential} = Credentials.store("xai-search-key", "xai-secret", "service")
    {:ok, view, _html} = live(conn, "/admin/mcp/managed/web")

    html =
      view
      |> form("#web-search-settings-form", %{
        "settings" => %{
          "default_backend" => "ollama",
          "credentials" => %{
            "ollama" => "",
            "minimax" => "",
            "z_ai" => "",
            "bigmodel" => ""
          },
          "x_search" => %{
            "credential" => "xai-search-key",
            "model" => "grok-4.3"
          }
        }
      })
      |> render_submit()

    assert html =~ "Web search settings saved"
    assert Settings.get("services.web_x_search.credential") == "xai-search-key"
    assert Settings.get("services.web_x_search.model") == "grok-4.3"
  end

  test "saves multiple live search models", %{conn: conn} do
    create_model_surface("openai-live", "gpt-5.5", :openai,
      preset_key: "openai",
      base_url: "https://api.openai.com/v1"
    )

    create_model_surface("xai-live", "grok-4.3", :openai,
      preset_key: "x-ai",
      base_url: "https://api.x.ai/v1"
    )

    {:ok, view, _html} = live(conn, "/admin/mcp/managed/web")

    html =
      view
      |> form("#web-search-settings-form", %{
        "settings" => %{
          "default_backend" => "ollama",
          "credentials" => %{
            "ollama" => "",
            "minimax" => "",
            "z_ai" => "",
            "bigmodel" => ""
          },
          "live_search" => %{
            "models" => ["openai-live/gpt-5.5", "xai-live/grok-4.3"]
          },
          "x_search" => %{
            "credential" => "",
            "model" => ""
          }
        }
      })
      |> render_submit()

    assert html =~ "Web search settings saved"

    assert Settings.get("services.web_live_search.models") == [
             "openai-live/gpt-5.5",
             "xai-live/grok-4.3"
           ]
  end

  test "rejects unsupported live search model settings", %{conn: conn} do
    create_model_surface("openai-live", "gpt-5.5", :openai,
      preset_key: "openai",
      base_url: "https://api.openai.com/v1"
    )

    {:ok, view, _html} = live(conn, "/admin/mcp/managed/web")

    html =
      render_submit(view, "save", %{
        "settings" => %{
          "default_backend" => "ollama",
          "credentials" => %{
            "ollama" => "",
            "minimax" => "",
            "z_ai" => "",
            "bigmodel" => ""
          },
          "live_search" => %{
            "models" => ["unsupported/model"]
          },
          "x_search" => %{
            "credential" => "",
            "model" => ""
          }
        }
      })

    assert html =~ "Choose supported live search models"
    assert Settings.get("services.web_live_search.models") == []
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

    {:ok, view, html} = live(conn, "/admin/mcp/managed/web?tab=debug")

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

  defp create_provider_api(provider_name, preset_key, base_url) do
    credential_name = "#{provider_name}-credential"
    {:ok, _credential} = Credentials.store(credential_name, "#{provider_name}-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: provider_name,
        credential: credential_name,
        preset_key: preset_key
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: base_url
      })

    api
  end

  defp create_model_surface(provider_name, model_id, api_surface, opts \\ []) do
    credential_name = "#{provider_name}-credential"
    {:ok, _credential} = Credentials.store(credential_name, "#{provider_name}-secret", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: provider_name,
        credential: credential_name,
        preset_key: Keyword.get(opts, :preset_key),
        enabled: Keyword.get(opts, :provider_enabled, true)
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: api_surface,
        base_url: Keyword.get(opts, :base_url, "https://#{provider_name}.example.test/v1"),
        enabled: Keyword.get(opts, :api_enabled, true)
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: model_id,
        source: :manual,
        enabled: Keyword.get(opts, :model_enabled, true)
      })

    {:ok, surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: Keyword.get(opts, :surface_enabled, true)
      })

    surface
  end
end
