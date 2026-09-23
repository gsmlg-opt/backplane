defmodule Backplane.Admin.ProvidersLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.LLM.OpenAICodex
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

  describe "index" do
    test "renders provider list page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/llama/providers")

      assert html =~ "LLM Providers"
      assert html =~ ~s(href="/llama/providers/new")
      refute html =~ "New Provider"
    end

    test "renders the dedicated new provider page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/llama/providers/new")

      assert html =~ "Add LLM Provider"
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
      assert html =~ "Moonshot.cn"
      assert html =~ "OpenAI-compatible API"
      assert html =~ "Anthropic Messages API"
      assert html =~ "provider-name"
      assert html =~ "provider-credential"
      assert html =~ "test-cred (llm)"
      assert html =~ "provider-openai-base-url"
      assert html =~ "provider-anthropic-base-url"
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
               "#provider-google-base-url[value='https://generativelanguage.googleapis.com/v1beta']"
             )

      assert has_element?(view, "#provider-google-generate-content-enabled[checked]")

      assert has_element?(
               view,
               "#provider-credential option[value='test-cred']",
               "test-cred (llm)"
             )

      refute has_element?(view, "#provider-credential option[value='openai-codex']")
      refute has_element?(view, "#provider-credential option[value='google-antigravity']")
      refute has_element?(view, "#provider-openai-responses-enabled")
    end

    test "selecting a provider preset repopulates the form defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      ollama_html =
        view
        |> element("button[phx-value-preset='ollama']")
        |> render_click()

      assert ollama_html =~ "http://localhost:11434/v1"
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
      assert has_element?(view, "#provider-openai-base-url[value='https://ollama.com/v1']")
      assert has_element?(view, "#provider-anthropic-base-url[value='https://ollama.com']")
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

      assert has_element?(view, "#provider-openai-chat-completions-enabled[checked]")
      assert has_element?(view, "#provider-openai-responses-enabled[checked]")

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "deepseek-test",
          "credential" => "test-cred",
          "base_url" => "https://api.deepseek.com",
          "rpm_limit" => "60",
          "default_headers" => "{}",
          "openai_enabled" => "true",
          "openai_base_url" => "https://api.deepseek.com",
          "openai_model_discovery_enabled" => "true",
          "openai_model_discovery_path" => "/models",
          "openai_default_headers" => "{}",
          "anthropic_enabled" => "true",
          "anthropic_base_url" => "https://api.deepseek.com/anthropic",
          "anthropic_model_discovery_enabled" => "true",
          "anthropic_model_discovery_path" => "/v1/models",
          "anthropic_default_headers" => ~s({"anthropic-version":"2023-06-01"})
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
                 native_protocols: [:anthropic_messages]
               },
               %{
                 api_surface: :openai,
                 base_url: "https://api.deepseek.com",
                 native_protocols: [:openai_chat_completions, :openai_responses]
               }
             ] = apis
    end

    test "deepseek creation preserves manually disabled openai responses", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='deepseek']")
      |> render_click()

      assert has_element?(view, "#provider-openai-chat-completions-enabled[checked]")
      assert has_element?(view, "#provider-openai-responses-enabled[checked]")

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "deepseek-chat-only",
          "credential" => "test-cred",
          "openai_chat_completions_enabled" => "true",
          "openai_responses_enabled" => "false"
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")

      provider = Repo.get_by!(Provider, name: "deepseek-chat-only")
      assert provider.preset_key == "deepseek"

      assert [
               %{api_surface: :anthropic, native_protocols: [:anthropic_messages]},
               %{api_surface: :openai, native_protocols: [:openai_chat_completions]}
             ] =
               ProviderApi.list_for_provider(provider.id)
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
          "base_url" => "https://api.moonshot.cn/v1",
          "rpm_limit" => "",
          "default_headers" => "{}",
          "openai_enabled" => "true",
          "openai_base_url" => "https://api.moonshot.cn/v1",
          "openai_model_discovery_enabled" => "true",
          "openai_model_discovery_path" => "/models",
          "openai_default_headers" => "{}",
          "anthropic_enabled" => "false",
          "anthropic_base_url" => "",
          "anthropic_model_discovery_enabled" => "false",
          "anthropic_model_discovery_path" => "",
          "anthropic_default_headers" => "{}"
        }
      })
      |> render_submit()

      assert_redirect(view, "/llama/providers")

      provider = Repo.get_by!(Provider, name: "moonshot-test")
      assert provider.preset_key == "moonshot-cn"

      assert [%{api_surface: :openai, base_url: "https://api.moonshot.cn/v1"}] =
               ProviderApi.list_for_provider(provider.id)
    end

    test "creates, reopens, and disables a Google native API surface", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/llama/providers/new")

      view
      |> element("button[phx-value-preset='google-gemini-developer']")
      |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "provider" => %{
          "name" => "google-native-test",
          "credential" => "test-cred",
          "base_url" => "https://generativelanguage.googleapis.com/v1beta",
          "rpm_limit" => "",
          "default_headers" => "{}",
          "google_enabled" => "true",
          "google_base_url" => "https://generativelanguage.googleapis.com/v1beta",
          "google_generate_content_enabled" => "true",
          "google_model_discovery_enabled" => "true",
          "google_model_discovery_path" => "/models",
          "google_default_headers" => "{}"
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
                 native_protocols: [:google_generate_content]
               }
             ] = ProviderApi.list_for_provider(provider.id)

      {:ok, view, html} = live(conn, "/llama/providers/#{provider.id}")
      assert html =~ "Google GenerateContent API"
      assert html =~ "Google GenerateContent"
      refute html =~ "Responses"

      view
      |> form("form[phx-submit=save_provider]", %{
        "provider" => %{
          "name" => "google-native-test",
          "credential" => "test-cred",
          "enabled" => "true",
          "rpm_limit" => "",
          "default_headers" => "{}",
          "google_enabled" => "false",
          "google_base_url" => "https://generativelanguage.googleapis.com/v1beta",
          "google_generate_content_enabled" => "true",
          "google_model_discovery_enabled" => "true",
          "google_model_discovery_path" => "/models",
          "google_default_headers" => "{}"
        }
      })
      |> render_submit()

      assert [%{api_surface: :google, enabled: false}] =
               ProviderApi.list_for_provider(provider.id)
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
            "base_url" => "https://api.openai.com/v1",
            "rpm_limit" => "",
            "default_headers" => "{}",
            "openai_enabled" => "true",
            "openai_base_url" => "https://api.openai.com/v1",
            "openai_model_discovery_enabled" => "true",
            "openai_model_discovery_path" => "/models",
            "openai_default_headers" => "{}",
            "anthropic_enabled" => "false",
            "anthropic_base_url" => "",
            "anthropic_model_discovery_enabled" => "false",
            "anthropic_model_discovery_path" => "",
            "anthropic_default_headers" => "{}"
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
          "base_url" => OpenAICodex.default_backend_base_url(),
          "rpm_limit" => "",
          "default_headers" => "{}",
          "openai_enabled" => "true",
          "openai_base_url" => OpenAICodex.default_backend_base_url(),
          "openai_model_discovery_enabled" => "true",
          "openai_model_discovery_path" => "/models",
          "openai_default_headers" => "{}",
          "anthropic_enabled" => "false",
          "anthropic_base_url" => "",
          "anthropic_model_discovery_enabled" => "false",
          "anthropic_model_discovery_path" => "",
          "anthropic_default_headers" => "{}"
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
                 native_protocols: [:openai_responses]
               }
             ] =
               ProviderApi.list_for_provider(provider.id)

      assert base_url == OpenAICodex.default_backend_base_url()
    end

    test "shows a created provider", %{conn: conn} do
      {provider, _openai_api, _anthropic_api} = create_provider_with_apis()

      {:ok, _view, html} = live(conn, "/llama/providers")

      assert html =~ "LLM Providers"
      assert html =~ "anthropic-prod"
      assert html =~ "Anthropic"
      assert html =~ "https://api.example.com/anthropic"
      assert html =~ ~s(href="/llama/providers/#{provider.id}")
    end

    test "provider detail edits provider and manages models", %{conn: conn} do
      {provider, openai_api, anthropic_api} = create_provider_with_apis()

      {:ok, view, html} = live(conn, "/llama/providers/#{provider.id}")

      assert html =~ "Edit Provider"
      assert html =~ "Add Model"
      assert html =~ "Load Models from API"
      refute html =~ "provider-models-table"
      refute html =~ "delete-model-modal"

      view
      |> form("form[phx-submit=save_provider]", %{
        "provider" => %{
          "name" => "anthropic-prod",
          "credential" => "test-cred",
          "enabled" => "true",
          "rpm_limit" => "120",
          "default_headers" => "{}",
          "openai_enabled" => "true",
          "openai_base_url" => "https://api.example.com/v2",
          "openai_chat_completions_enabled" => "false",
          "openai_responses_enabled" => "true",
          "openai_model_discovery_enabled" => "true",
          "openai_model_discovery_path" => "/models",
          "openai_default_headers" => "{}",
          "anthropic_enabled" => "true",
          "anthropic_base_url" => "https://api.example.com/anthropic",
          "anthropic_model_discovery_enabled" => "true",
          "anthropic_model_discovery_path" => "/v1/models",
          "anthropic_default_headers" => "{}"
        }
      })
      |> render_submit()

      updated_provider = Repo.get!(Provider, provider.id)
      assert updated_provider.rpm_limit == 120

      updated_openai_api = Repo.get!(ProviderApi, openai_api.id)
      assert updated_openai_api.base_url == "https://api.example.com/v2"
      assert updated_openai_api.native_protocols == [:openai_responses]

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
      previous = Application.get_env(:backplane, :llm_model_discovery_req_options)

      Application.put_env(:backplane, :llm_model_discovery_req_options,
        plug: {Req.Test, __MODULE__}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:backplane, :llm_model_discovery_req_options, previous)
        else
          Application.delete_env(:backplane, :llm_model_discovery_req_options)
        end
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v1/models"
        assert ["Bearer sk-test"] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "provider-api-model"}
            ]
          })
        )
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

      {:ok, view, _html} = live(conn, "/llama/providers/#{provider.id}")

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

      {:ok, _view, html} = live(conn, "/llama/providers/#{provider.id}")

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
      previous = Application.get_env(:backplane, :llm_model_discovery_req_options)

      Application.put_env(:backplane, :llm_model_discovery_req_options,
        plug: {Req.Test, __MODULE__}
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:backplane, :llm_model_discovery_req_options, previous)
        else
          Application.delete_env(:backplane, :llm_model_discovery_req_options)
        end
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/backend-api/codex/models"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer oauth-token"]
        assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["codex-account"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "models" => [%{"slug" => "gpt-codex-live-test", "capabilities" => %{}}]
          })
        )
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

      {:ok, view, _html} = live(conn, "/llama/providers/#{provider.id}")

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
