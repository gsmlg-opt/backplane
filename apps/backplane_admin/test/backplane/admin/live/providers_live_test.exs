defmodule Backplane.Admin.ProvidersLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.LLM.OpenAICodex
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  setup do
    Credentials.store("test-cred", "sk-test", "llm")
    Credentials.store("openai-codex", "{}", "llm", %{"auth_type" => "openai_oauth"})
    Credentials.store("google-antigravity", "{}", "llm", %{"auth_type" => "google_oauth"})
    :ok
  end

  defp create_provider_with_apis(name \\ "anthropic-prod") do
    {:ok, provider} =
      Provider.create(%{
        name: name,
        preset_key: "custom",
        base_url: "https://api.example.com",
        credential: "test-cred"
      })

    {:ok, openai_api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1",
        model_discovery_path: "/models"
      })

    {:ok, anthropic_api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :anthropic,
        base_url: "https://api.example.com/anthropic",
        model_discovery_path: "/v1/models"
      })

    {Provider.get(provider.id), openai_api, anthropic_api}
  end

  describe "provider connections" do
    test "Platform creates only a connection and defers API configuration to LLM", %{conn: conn} do
      {:ok, view, _} = live(conn, "/llama/providers/new?preset=openai")
      assert has_element?(view, "button[phx-value-preset='openai']", "OpenAI Platform")
      refute has_element?(view, "#provider-credential option[value='openai-codex']")
      refute has_element?(view, "#provider-native-capabilities")
      refute has_element?(view, "#provider-openai-responses-websocket")
      refute has_element?(view, "#provider-openai-discovery-enabled")

      view
      |> form("#provider-form", %{
        "provider" => %{"name" => "platform-once", "credential" => "test-cred"}
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")
      provider = Repo.get_by!(Provider, name: "platform-once")
      refute Repo.get_by(Service, provider_id: provider.id)
      assert [] == ProviderModel.list_for_provider(provider.id)

      assert [
               %ProviderApi{
                 native_protocols: [],
                 responses_websocket: false,
                 model_discovery_enabled: false
               }
             ] = ProviderApi.list_for_provider(provider.id)
    end

    test "MiniMax has one provider URL and configures protocol URLs and headers in LLM", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/llama/providers/new?preset=minimax")
      assert has_element?(view, "#provider-base-url[value='https://api.minimaxi.com']")
      refute has_element?(view, "#provider-openai-base-url")
      refute has_element?(view, "#provider-anthropic-base-url")
      refute has_element?(view, "#provider-anthropic-default-headers")
      refute has_element?(view, "#provider-default-headers")

      view
      |> form("#provider-form", %{
        "provider" => %{
          "name" => "minimax-one-base",
          "credential" => "test-cred",
          "base_url" => "https://proxy.example.test/minimax"
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")
      provider = Repo.get_by!(Provider, name: "minimax-one-base")
      assert provider.base_url == "https://proxy.example.test/minimax"
      assert [anthropic, openai] = ProviderApi.list_for_provider(provider.id)
      assert anthropic.base_url == "https://proxy.example.test/minimax/anthropic"
      assert openai.base_url == "https://proxy.example.test/minimax/v1"
      {:ok, llm, _} = live(conn, "/llama/llm/new")

      assert has_element?(
               llm,
               "#llm-anthropic-path[value='/minimax/anthropic']"
             )

      llm
      |> form("#llm-form", %{
        "llm" => %{
          "apis" => %{
            "anthropic" => %{
              "path" => "/custom/anthropic",
              "default_headers" => ~s({"anthropic-version":"2023-06-01"})
            }
          }
        }
      })
      |> render_submit()

      assert_patch(llm, "/llama/llm")
      assert has_element?(llm, "#edit-llm-#{provider.id}")
      assert has_element?(llm, "#llm-configurations tbody tr:only-child")
      refute has_element?(llm, "#llm-configurations #edit-llm-#{anthropic.id}")
      render_patch(llm, "/llama/llm/#{provider.id}/edit")
      assert has_element?(llm, "#llm-openai-path")
      assert has_element?(llm, "#llm-anthropic-default-headers")

      assert ProviderApi.get(anthropic.id).base_url ==
               "https://proxy.example.test/custom/anthropic"

      assert ProviderApi.get(anthropic.id).default_headers == %{
               "anthropic-version" => "2023-06-01"
             }

      assert ProviderApi.get(openai.id).base_url == openai.base_url
      assert Provider.get(provider.id).base_url == "https://proxy.example.test/minimax"
    end

    test "connection edits preserve LLM and native API policy including disabled state", %{
      conn: conn
    } do
      {provider, api, _} = create_provider_with_apis("preserve-api-policy")

      {:ok, api} =
        ProviderApi.update(api, %{
          native_protocols: [:openai_responses],
          responses_websocket: true,
          responses_lifecycle: true,
          enabled: false
        })

      {:ok, provider} = Provider.update(provider, %{enabled: false})

      {:ok, service} =
        Service.create(%{
          provider_id: provider.id,
          kind: :images,
          models: ["image-old"],
          default_model: "image-old",
          request_timeout_ms: 42000,
          enabled: false
        })

      {:ok, view, _} = live(conn, "/llama/providers/#{provider.id}")
      refute has_element?(view, "#provider-native-capabilities")
      refute has_element?(view, "#provider-openai-responses-websocket")
      refute has_element?(view, "#provider-enabled")

      view
      |> form("#provider-form", %{
        "provider" => %{"base_url" => "https://changed.example.test"}
      })
      |> render_submit()

      assert Provider.get(provider.id).base_url == "https://changed.example.test"
      refute Provider.get(provider.id).enabled

      assert %ProviderApi{
               base_url: "https://api.example.com/v1",
               enabled: false,
               native_protocols: [:openai_responses],
               responses_websocket: true,
               responses_lifecycle: true,
               model_discovery_enabled: true
             } = ProviderApi.get(api.id)

      assert %Service{enabled: false, models: ["image-old"], request_timeout_ms: 42000} =
               Service.get(service.id)

      render_submit(view, "save_provider", %{
        "provider" => %{
          "name" => provider.name,
          "credential" => "test-cred",
          "base_url" => "https://changed.example.test/v1",
          "enabled" => "true",
          "openai_responses_websocket" => "false",
          "native_capabilities" => ["images"]
        }
      })

      refute Provider.get(provider.id).enabled
      assert ProviderApi.get(api.id).responses_websocket
      refute Service.get(service.id).enabled
    end
  end

  describe "index" do
    test "renders provider list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/llama/providers")

      assert html =~ "Providers"
      assert html =~ ~s(href="/llama/providers/new")
      refute html =~ "New Provider"
    end

    test "renders the dedicated new provider page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/llama/providers/new")

      assert html =~ "Add Provider"
      assert html =~ "DeepSeek"
      assert html =~ "Z.ai"
      assert html =~ "MiniMax"
      assert html =~ "OpenCode Go"
      assert html =~ "OpenRouter"
      assert html =~ "Ollama"
      assert html =~ "Ollama Cloud"
      assert has_element?(view, "button[phx-value-preset='ollama']", "Ollama")
      assert has_element?(view, "button[phx-value-preset='ollama-cloud']", "Ollama Cloud")
      assert html =~ "Custom"
      assert html =~ "OpenAI"
      assert html =~ "OpenAI Codex"
      assert html =~ "Anthropic"
      assert html =~ "x.ai"
      assert html =~ "Google Gemini Developer API"
      assert html =~ "Google Antigravity"
      assert html =~ "Moonshot.cn"
      refute html =~ "OpenAI-compatible API"
      refute html =~ "Anthropic Messages API"
      assert html =~ "provider-name"
      assert html =~ "provider-credential"
      assert html =~ "test-cred (llm)"
      assert html =~ "provider-base-url"
      refute html =~ "provider-openai-base-url"
      refute html =~ "provider-anthropic-base-url"
      refute html =~ "provider-api-key"
    end

    test "openai codex preset defaults to openai oauth credential options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='openai-codex']")
      |> render_click()

      assert has_element?(
               view,
               "#provider-credential option[value='openai-codex']",
               "openai-codex (openai_oauth)"
             )

      assert has_element?(view, "#provider-credential option[value='openai-codex'][selected]")
      refute has_element?(view, "#provider-credential option[value='test-cred']")
    end

    test "does not expose retired Google compatibility presets", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      refute has_element?(view, "button[phx-value-preset='google-ai-studio']")
      refute has_element?(view, "button[phx-value-preset='google-gemini-openai-compatible']")
    end

    test "google native preset defaults to its API-key credential and surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='google-gemini-developer']")
      |> render_click()

      assert has_element?(
               view,
               "#provider-base-url[value='https://generativelanguage.googleapis.com/v1beta']"
             )

      refute has_element?(view, "#provider-google-generate-content-enabled")

      assert has_element?(
               view,
               "#provider-credential option[value='test-cred']",
               "test-cred (llm)"
             )

      refute has_element?(view, "#provider-credential option[value='openai-codex']")
      refute has_element?(view, "#provider-credential option[value='google-antigravity']")
      refute has_element?(view, "#provider-openai-responses-enabled")
    end

    test "Antigravity preset accepts only Google OAuth and shows its native configuration", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='google-antigravity']")
      |> render_click()

      assert has_element?(
               view,
               "#provider-base-url[value='https://cloudcode-pa.googleapis.com']"
             )

      refute has_element?(view, "#provider-google-antigravity-enabled")

      refute has_element?(view, "#provider-antigravity-discovery-path")

      assert has_element?(
               view,
               "#provider-credential option[value='google-antigravity'][selected]"
             )

      refute has_element?(view, "#provider-credential option[value='test-cred']")
      refute has_element?(view, "#provider-openai-base-url")
      refute has_element?(view, "#provider-anthropic-base-url")
    end

    test "selecting a provider preset repopulates the form defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      ollama_html =
        view
        |> element("button[phx-value-preset='ollama']")
        |> render_click()

      refute has_element?(view, "#provider-openai-base-url")
      assert ollama_html =~ "http://localhost:11434"

      moonshot_html =
        view
        |> element("button[phx-value-preset='moonshot-cn']")
        |> render_click()

      assert moonshot_html =~ "moonshot-cn"
      assert moonshot_html =~ "https://api.moonshot.cn/v1"
      refute moonshot_html =~ "http://localhost:11434/v1"
    end

    test "ollama cloud preset populates hosted compatibility defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='ollama-cloud']")
      |> render_click()

      assert has_element?(view, "#provider-name[value='ollama-cloud']")
      assert has_element?(view, "#provider-base-url[value='https://ollama.com']")
      refute has_element?(view, "#provider-openai-base-url")
      refute has_element?(view, "#provider-anthropic-base-url")
      assert has_element?(view, "#provider-credential option[value='test-cred']")
      refute has_element?(view, "#provider-credential option[value='openai-codex']")
      refute has_element?(view, "#provider-credential option[value='google-antigravity']")

      refute has_element?(
               view,
               "#provider-openai-base-url[value='http://localhost:11434/v1']"
             )
    end

    test "creates a provider with openai and anthropic API surfaces", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      refute has_element?(view, "#provider-openai-chat-completions-enabled")
      refute has_element?(view, "#provider-openai-responses-enabled")

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "deepseek-test",
          "credential" => "test-cred",
          "rpm_limit" => "60",
          "base_url" => "https://api.deepseek.com"
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")

      provider = Repo.get_by!(Provider, name: "deepseek-test")

      assert [%{target_id: audit_id}] =
               Backplane.Admin.Audit.list(%{action: "provider.create", target_id: provider.id})

      assert audit_id == provider.id
      assert provider.preset_key == "deepseek"
      assert provider.credential == "test-cred"
      assert provider.rpm_limit == 60

      apis = ProviderApi.list_for_provider(provider.id)

      assert [
               %{
                 api_surface: :anthropic,
                 base_url: "https://api.deepseek.com/anthropic",
                 native_protocols: []
               },
               %{
                 api_surface: :openai,
                 base_url: "https://api.deepseek.com",
                 native_protocols: []
               }
             ] = apis
    end

    test "creates a provider from a selected preset", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='moonshot-cn']")
      |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "moonshot-test",
          "credential" => "test-cred",
          "rpm_limit" => "",
          "base_url" => "https://api.moonshot.cn/v1"
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")

      provider = Repo.get_by!(Provider, name: "moonshot-test")
      assert provider.preset_key == "moonshot-cn"

      assert [%{api_surface: :openai, base_url: "https://api.moonshot.cn/v1"}] =
               ProviderApi.list_for_provider(provider.id)
    end

    test "creates and updates a Google connection without changing its enablement", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='google-gemini-developer']")
      |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "google-native-test",
          "credential" => "test-cred",
          "rpm_limit" => "",
          "base_url" => "https://generativelanguage.googleapis.com/v1beta"
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")

      provider = Repo.get_by!(Provider, name: "google-native-test")

      assert [
               %{
                 api_surface: :google,
                 base_url: "https://generativelanguage.googleapis.com/v1beta",
                 enabled: true,
                 native_protocols: []
               }
             ] = ProviderApi.list_for_provider(provider.id)

      {:ok, view, html} = live(conn, "/llama/providers/#{provider.id}")
      refute html =~ "Google GenerateContent API"

      assert has_element?(
               view,
               "#provider-base-url[value='https://generativelanguage.googleapis.com/v1beta']"
             )

      refute has_element?(view, "#provider-openai-responses-enabled")

      view
      |> form("form[phx-submit=save_provider]", %{
        "provider" => %{
          "name" => "google-native-test",
          "credential" => "test-cred",
          "rpm_limit" => "",
          "base_url" => "https://generativelanguage.googleapis.com/v1beta"
        }
      })
      |> render_submit()

      assert [%{api_surface: :google, enabled: true, native_protocols: []}] =
               ProviderApi.list_for_provider(provider.id)
    end

    test "Antigravity project configuration is owned by LLM", %{conn: conn} do
      {:ok, view, _} = live(conn, "/llama/providers/new?preset=google-antigravity")
      refute has_element?(view, "#provider-antigravity-project-id")

      view
      |> form("#provider-form", %{
        "provider" => %{"name" => "antigravity-native-test", "credential" => "google-antigravity"}
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")
      provider = Repo.get_by!(Provider, name: "antigravity-native-test")
      assert [%{backend_config: config} = api] = ProviderApi.list_for_provider(provider.id)
      assert config == %{}

      {:ok, view, _} = live(conn, "/llama/llm/new")
      assert has_element?(view, "#llm-antigravity-project-id")

      for {project, version} <- [{"project-one", "1.0"}, {"project-two", "2.0"}] do
        render_submit(view, "save", %{
          "llm" => %{
            "apis" => %{
              "antigravity" => %{
                "google_antigravity" => "true",
                "project_id" => project,
                "user_agent" => "BackplaneAdmin/" <> version,
                "client_version" => version
              }
            }
          }
        })

        assert_patch(view, "/llama/llm")

        assert ProviderApi.get(api.id).backend_config == %{
                 "project_id" => project,
                 "user_agent" => "BackplaneAdmin/" <> version,
                 "client_version" => version
               }

        render_patch(view, "/llama/llm/#{provider.id}/edit")
        assert has_element?(view, "#llm-antigravity-project-id[value='#{project}']")
      end
    end

    test "renders native Antigravity model metadata and keeps missing quota unavailable", %{
      conn: conn
    } do
      {:ok, provider} =
        Provider.create(%{
          name: "antigravity-metadata-test",
          preset_key: "google-antigravity",
          credential: "google-antigravity"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :antigravity,
          base_url: "https://cloudcode-pa.googleapis.com"
        })

      for {model_id, metadata} <- [
            {"gemini-quota",
             %{
               "displayName" => "Gemini With Quota",
               "quotaInfo" => %{
                 "remainingFraction" => 0.75,
                 "resetTime" => "2026-09-24T00:00:00Z"
               },
               "nativeUnknown" => %{"preserved" => true}
             }},
            {"gemini-no-quota", %{"displayName" => "Gemini Without Quota"}}
          ] do
        {:ok, model} =
          ProviderModel.create(%{
            provider_id: provider.id,
            model: model_id,
            source: :discovered,
            metadata: metadata
          })

        {:ok, _surface} =
          ProviderModelSurface.create(%{
            provider_model_id: model.id,
            provider_api_id: api.id,
            metadata: metadata
          })
      end

      {:ok, _view, html} = live(conn, "/llama/providers/#{provider.id}/models")

      assert html =~ "Gemini With Quota"
      assert html =~ "remainingFraction"
      assert html =~ "0.75"
      assert html =~ "2026-09-24T00:00:00Z"
      assert html =~ "nativeUnknown"
      assert html =~ "Gemini Without Quota"
      assert html =~ "Quota:"
      assert html =~ "Unavailable"
      refute html =~ "Quota: 0"
    end

    test "openai codex preset rejects non openai oauth credentials", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='openai-codex']")
      |> render_click()

      html =
        render_submit(view, "save", %{
          "provider" => %{
            "name" => "openai-codex-test",
            "credential" => "test-cred",
            "rpm_limit" => "",
            "base_url" => "https://api.openai.com/v1"
          }
        })

      assert html =~ "Credential must use openai_oauth auth type"
      refute Repo.get_by(Provider, name: "openai-codex-test")
    end

    test "creates openai codex provider with openai oauth credential", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='openai-codex']")
      |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "openai-codex-test",
          "credential" => "openai-codex",
          "rpm_limit" => "",
          "base_url" => OpenAICodex.default_backend_base_url()
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")

      provider = Repo.get_by!(Provider, name: "openai-codex-test")
      assert provider.preset_key == "openai-codex"
      assert provider.credential == "openai-codex"

      assert [
               %{
                 api_surface: :openai,
                 base_url: base_url,
                 native_protocols: []
               }
             ] =
               ProviderApi.list_for_provider(provider.id)

      assert base_url == OpenAICodex.default_backend_base_url()
    end

    test "lists the Provider preset, credential and Base URL in separate columns", %{conn: conn} do
      {provider, openai, anthropic} = create_provider_with_apis()

      {:ok, view, html} = live(conn, "/llama/providers")

      assert has_element?(view, "#llm-providers-table th:nth-child(2)", "Preset")
      assert has_element?(view, "#llm-providers-table th:nth-child(3)", "Credential")
      assert has_element?(view, "#llm-providers-table th:nth-child(4)", "Base URL")
      assert has_element?(view, "#llm-providers-table td:nth-child(2)", provider.preset_key)
      assert has_element?(view, "#llm-providers-table td:nth-child(3)", provider.credential)
      assert has_element?(view, "#llm-providers-table td:nth-child(4)", provider.base_url)
      refute html =~ openai.base_url
      refute html =~ anthropic.base_url
      assert html =~ ~s(href="/llama/providers/#{provider.id}")
    end

    test "provider detail edits provider and manages models", %{conn: conn} do
      {provider, openai_api, anthropic_api} = create_provider_with_apis()

      {:ok, view, html} = live(conn, "/llama/providers/#{provider.id}")

      assert html =~ "Edit Provider"
      refute html =~ "Add Model"
      refute html =~ "Load Models from API"
      assert html =~ "Manage LLM models"
      refute html =~ "provider-models-table"
      refute html =~ "delete-model-modal"

      view
      |> form("form[phx-submit=save_provider]", %{
        "provider" => %{
          "name" => "anthropic-prod",
          "credential" => "test-cred",
          "rpm_limit" => "120",
          "base_url" => "https://api.example.com/v2"
        }
      })
      |> render_submit()

      updated_provider = Repo.get!(Provider, provider.id)
      assert updated_provider.rpm_limit == 120

      updated_openai_api = Repo.get!(ProviderApi, openai_api.id)
      assert updated_provider.base_url == "https://api.example.com/v2"
      assert updated_openai_api.base_url == "https://api.example.com/v1"
      assert updated_openai_api.native_protocols == openai_api.native_protocols

      {:ok, view, model_html} = live(conn, "/llama/llm/#{provider.id}/models")
      refute model_html =~ "Edit Provider"
      assert model_html =~ "Add Model"

      view
      |> form("form[phx-submit=add_model]", %{
        "model" => %{
          "model" => "provider-model-a",
          "display_name" => "Provider Model A",
          "enabled" => "true",
          "metadata" => "{}",
          "surface_#{openai_api.id}" => "true",
          "surface_#{anthropic_api.id}" => "false"
        }
      })
      |> render_submit()

      model = Repo.get_by!(ProviderModel, provider_id: provider.id, model: "provider-model-a")
      assert model.display_name == "Provider Model A"
      assert model.enabled
      assert render(view) =~ "provider-models-table"

      assert %ProviderModelSurface{enabled: true} =
               ProviderModelSurface.get_by_model_and_api(model.id, openai_api.id)

      refute ProviderModelSurface.get_by_model_and_api(model.id, anthropic_api.id)

      view
      |> element("[phx-click='edit_model'][phx-value-id='#{model.id}']", "Edit")
      |> render_click()

      view
      |> form("form[phx-submit=update_model]", %{
        "model" => %{
          "model" => "provider-model-b",
          "display_name" => "Provider Model B",
          "enabled" => "true",
          "metadata" => "{}",
          "surface_#{openai_api.id}" => "true",
          "surface_#{anthropic_api.id}" => "true"
        }
      })
      |> render_submit()

      model = Repo.get!(ProviderModel, model.id)
      assert model.model == "provider-model-b"

      assert %ProviderModelSurface{enabled: true} =
               ProviderModelSurface.get_by_model_and_api(model.id, anthropic_api.id)

      view
      |> element("[phx-click='toggle_model'][phx-value-id='#{model.id}']")
      |> render_click()

      refute Repo.get!(ProviderModel, model.id).enabled

      html =
        view
        |> element("#open-delete-model-modal-#{model.id}")
        |> render_click()

      assert html =~ "delete-model-modal"
      assert html =~ "Delete Model"
      assert html =~ "provider-model-b"
      assert Repo.get(ProviderModel, model.id)

      view
      |> element("#delete-model-confirm")
      |> render_click()

      refute Repo.get(ProviderModel, model.id)
    end

    test "provider detail loads models from the API", %{conn: conn} do
      previous = Application.get_env(:backplane, :llm_model_discovery_http_options)

      Application.put_env(:backplane, :llm_model_discovery_http_options,
        adapter: {HTTP.Test, __MODULE__}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:backplane, :llm_model_discovery_http_options, previous)
        else
          Application.delete_env(:backplane, :llm_model_discovery_http_options)
        end
      end)

      HTTP.Test.stub(__MODULE__, fn request ->
        assert request.url.path == "/v1/models"
        assert ["Bearer sk-test"] = HTTP.Headers.get_all(request.headers, "authorization")

        HTTP.Test.json(%{
          "data" => [
            %{"id" => "provider-api-model"}
          ]
        })
      end)

      {:ok, provider} =
        Provider.create(%{
          name: "api-load-provider",
          preset_key: "custom",
          credential: "test-cred"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://api.example.com/v1",
          model_discovery_path: "/models"
        })

      {:ok, old_model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "provider-stale-model",
          source: :discovered,
          enabled: true
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: old_model.id,
          provider_api_id: api.id,
          enabled: true
        })

      {:ok, view, _html} = live(conn, "/llama/providers/#{provider.id}/models")

      html =
        view
        |> element("[phx-click='reload_models']", "Load Models from API")
        |> render_click()

      assert html =~ "provider-api-model"
      assert Repo.get_by!(ProviderModel, provider_id: provider.id, model: "provider-api-model")

      stale_model =
        Repo.get_by!(ProviderModel, provider_id: provider.id, model: "provider-stale-model")

      refute stale_model.enabled
      refute ProviderModelSurface.get_by_model_and_api(stale_model.id, api.id)
      refute html =~ "provider-stale-model"
    end

    test "shows Google native model metadata and discovery state without inferring unknown capabilities",
         %{
           conn: conn
         } do
      discovered_at = ~U[2026-09-23 08:15:00.000000Z]

      {:ok, provider} =
        Provider.create(%{
          name: "google-native-metadata",
          preset_key: "google-gemini-developer",
          credential: "test-cred"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :google,
          base_url: "https://generativelanguage.googleapis.com/v1beta",
          model_discovery_path: "/models",
          last_discovered_at: discovered_at
        })

      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: "gemini-3-pro-preview",
          display_name: "Gemini 3 Pro Preview",
          source: :discovered,
          metadata: %{
            "name" => "models/gemini-3-pro-preview",
            "displayName" => "Gemini 3 Pro Preview",
            "inputTokenLimit" => 1_048_576,
            "outputTokenLimit" => 65_536,
            "supportedGenerationMethods" => ["generateContent", "countTokens"]
          }
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: api.id,
          enabled: true,
          metadata: %{}
        })

      {:ok, _view, html} = live(conn, "/llama/providers/#{provider.id}/models")

      assert html =~ "Directory refresh"
      assert html =~ "API version: v1beta"
      assert html =~ "Credential auth: API key"
      assert html =~ "Last successful discovery"
      assert html =~ "never starts a generation"
      assert html =~ "2026-09-23"
      assert html =~ "Native Google GenerateContent"
      assert html =~ "Translation unavailable"
      assert html =~ "models/gemini-3-pro-preview"
      assert html =~ "Input token limit: 1048576"
      assert html =~ "Output token limit: 65536"
      assert html =~ "generateContent"
      assert html =~ "countTokens"
      assert html =~ "Unknown"
    end

    test "provider detail loads openai codex oauth models from api", %{conn: conn} do
      previous = Application.get_env(:backplane, :llm_model_discovery_http_options)

      Application.put_env(:backplane, :llm_model_discovery_http_options,
        adapter: {HTTP.Test, __MODULE__}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:backplane, :llm_model_discovery_http_options, previous)
        else
          Application.delete_env(:backplane, :llm_model_discovery_http_options)
        end
      end)

      HTTP.Test.stub(__MODULE__, fn request ->
        assert request.url.path == "/backend-api/codex/models"
        assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer oauth-token"]
        assert HTTP.Headers.get_all(request.headers, "chatgpt-account-id") == ["codex-account"]

        HTTP.Test.json(%{
          "models" => [%{"slug" => "gpt-codex-live-test", "capabilities" => %{}}]
        })
      end)

      expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

      {:ok, _credential} =
        Credentials.store_device_token(
          "openai-codex",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "id_token" => "codex-id-token",
            "access_token" => "oauth-token",
            "refresh_token" => "refresh-token",
            "expires_at" => expires_at
          },
          %{"account_id" => "codex-account"}
        )

      {:ok, provider} =
        Provider.create(%{
          name: "openai-codex-live",
          preset_key: "openai-codex",
          credential: "openai-codex"
        })

      {:ok, _api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: OpenAICodex.default_backend_base_url(),
          model_discovery_enabled: true,
          model_discovery_path: "/models"
        })

      {:ok, view, _html} = live(conn, "/llama/providers/#{provider.id}/models")

      html =
        view
        |> element("[phx-click='reload_models']", "Load Models from API")
        |> render_click()

      assert html =~ "gpt-codex-live-test"
      assert Repo.get_by!(ProviderModel, provider_id: provider.id, model: "gpt-codex-live-test")
    end

    test "retains stored retired provider rows without rendering a migration diagnostic", %{
      conn: conn
    } do
      {:ok, provider} =
        Provider.create(%{
          name: "google-ai-studio-legacy",
          preset_key: "google-ai-studio",
          credential: "google-antigravity"
        })

      {:ok, api} =
        ProviderApi.create(%{
          provider_id: provider.id,
          api_surface: :openai,
          base_url: "https://legacy.example.test/v1beta/openai",
          native_protocols: [:openai_chat_completions],
          model_discovery_path: "/models"
        })

      {:ok, _view, html} = live(conn, "/llama/providers/#{provider.id}")

      assert html =~ "https://legacy.example.test/v1beta/openai"
      assert html =~ "google-antigravity"
      refute html =~ "Legacy Google configuration"

      assert %Provider{preset_key: "google-ai-studio", credential: "google-antigravity"} =
               Repo.get!(Provider, provider.id)

      assert %ProviderApi{base_url: "https://legacy.example.test/v1beta/openai"} =
               Repo.get!(ProviderApi, api.id)
    end

    test "does not show soft-deleted providers", %{conn: conn} do
      {:ok, provider} =
        Provider.create(%{
          name: "anthropic-prod",
          preset_key: "custom",
          credential: "test-cred"
        })

      Provider.soft_delete(provider)

      {:ok, _view, html} = live(conn, "/llama/providers")

      refute html =~ "anthropic-prod"
    end
  end
end
