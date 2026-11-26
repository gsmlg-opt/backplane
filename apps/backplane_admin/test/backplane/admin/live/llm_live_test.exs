defmodule Backplane.Admin.LLMLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  setup do
    {:ok, _} = Credentials.store("llm-config-key", "never-render-this-secret", "llm")
    {:ok, _} = Credentials.store("llm-codex-key", "{}", "llm", %{"auth_type" => "openai_oauth"})
    {:ok, _} = Credentials.store("llm-google-key", "{}", "llm", %{"auth_type" => "google_oauth"})
    :ok
  end

  defp connection(attrs \\ %{}) do
    surface = Map.get(attrs, :api_surface, :openai)

    {:ok, provider} =
      Provider.create(%{
        name: Map.get(attrs, :name, "llm-provider"),
        base_url: "https://api.openai.com",
        credential: Map.get(attrs, :credential, "llm-config-key"),
        preset_key: Map.get(attrs, :preset_key, "openai")
      })

    urls = %{
      openai: "https://api.openai.com/v1",
      anthropic: "https://api.anthropic.com",
      google: "https://generativelanguage.googleapis.com/v1beta",
      antigravity: "https://cloudcode-pa.googleapis.com"
    }

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: surface,
        base_url: Map.fetch!(urls, surface),
        native_protocols: [],
        default_headers: %{"x-connection" => "preserve"},
        model_discovery_enabled: false
      })

    {provider, api}
  end

  test "Add selects an existing Provider without duplicating authentication or creating APIs",
       %{conn: conn} do
    {provider, api} = connection()
    {:ok, view, html} = live(conn, "/llama/llm/new")

    assert has_element?(view, "#llm-configuration-page")
    assert has_element?(view, "#llm-provider option[value='#{provider.id}']", provider.name)
    assert has_element?(view, "#llm-openai_chat_completions[checked]")
    assert has_element?(view, "#llm-openai_responses[checked]")
    assert has_element?(view, "#llm-openai-responses-websocket[checked]")
    refute has_element?(view, "#llm-form input[name='llm[credential]']")
    assert has_element?(view, "#llm-openai-path[value='/v1']")
    assert has_element?(view, "#llm-openai-default-headers")
    refute has_element?(view, "#llm-form input[name='llm[enabled]']")
    refute html =~ "never-render-this-secret"
    assert ProviderApi.get(api.id).native_protocols == []
    refute Repo.get_by(Service, provider_id: provider.id)
    assert ProviderModel.list_for_provider(provider.id) == []
  end

  test "configures and reopens Responses WebSocket, lifecycle and discovery independently", %{
    conn: conn
  } do
    {provider, api} = connection()
    {:ok, view, _} = live(conn, "/llama/llm/new")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "models_path" => "/available-models?scope=a%2Fb",
        "apis" => %{
          "openai" => %{
            "openai_chat_completions" => "false",
            "openai_responses" => "true",
            "responses_websocket" => "true",
            "responses_lifecycle" => "true",
            "responses_route_ttl_seconds" => "3600"
          }
        }
      }
    })
    |> render_submit()

    assert_patch(view, "/llama/llm")

    assert %ProviderApi{
             native_protocols: [:openai_responses],
             responses_websocket: true,
             responses_lifecycle: true,
             responses_route_ttl_seconds: 3600,
             model_discovery_enabled: true,
             model_discovery_path: "https://api.openai.com/available-models?scope=a%2Fb",
             base_url: "https://api.openai.com/v1",
             default_headers: %{"x-connection" => "preserve"},
             enabled: true
           } = ProviderApi.get(api.id)

    refute Repo.get_by(Service, provider_id: provider.id)
    assert ProviderModel.list_for_provider(provider.id) == []

    assert has_element?(
             view,
             "#models-llm-#{provider.id}[href='/llama/llm/#{provider.id}/models']"
           )

    assert has_element?(view, "#edit-llm-#{provider.id}[aria-label] svg")

    render_patch(view, "/llama/llm/#{provider.id}/edit")
    assert has_element?(view, "#llm-openai_responses[checked]")
    refute has_element?(view, "#llm-openai_chat_completions[checked]")
    assert has_element?(view, "#llm-openai-responses-websocket[checked]")
    assert has_element?(view, "#llm-openai-responses-lifecycle[checked]")

    assert has_element?(
             view,
             "input[name='llm[apis][openai][responses_route_ttl_seconds]'][value='3600']"
           )

    assert has_element?(
             view,
             "input[name='llm[models_path]'][value='/available-models?scope=a%2Fb']"
           )
  end

  test "DeepSeek can configure Chat Completions only", %{conn: conn} do
    {_provider, api} = connection(%{preset_key: "deepseek"})
    {:ok, view, _} = live(conn, "/llama/llm/new")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "apis" => %{
          "openai" => %{
            "openai_chat_completions" => "true",
            "openai_responses" => "false",
            "responses_websocket" => "false",
            "responses_lifecycle" => "false"
          }
        }
      }
    })
    |> render_submit()

    assert_patch(view, "/llama/llm")

    assert %ProviderApi{native_protocols: [:openai_chat_completions], responses_websocket: false} =
             ProviderApi.get(api.id)
  end

  test "invalid Responses WebSocket selection retains input and makes no write", %{conn: conn} do
    {_provider, api} = connection()
    {:ok, view, _} = live(conn, "/llama/llm/new")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "models_path" => "/keep-input",
        "apis" => %{
          "openai" => %{
            "openai_chat_completions" => "true",
            "openai_responses" => "false",
            "responses_websocket" => "true"
          }
        }
      }
    })
    |> render_submit()

    assert has_element?(view, "#llm-errors", "requires native OpenAI Responses")
    assert has_element?(view, "#llm-configuration-page")
    assert has_element?(view, "#llm-openai-responses-websocket[checked]")

    assert has_element?(
             view,
             "input[name='llm[models_path]'][value='/keep-input']"
           )

    assert ProviderApi.get(api.id).native_protocols == []
    refute ProviderApi.get(api.id).responses_websocket
  end

  test "LLM owns API URLs and headers while preserving provider identity and activation", %{
    conn: conn
  } do
    {provider, api} = connection()
    {:ok, api} = ProviderApi.update(api, %{native_protocols: [:openai_responses], enabled: false})
    {:ok, _} = Provider.update(provider, %{enabled: false})

    {:ok, service} =
      Service.create(%{
        provider_id: provider.id,
        kind: :images,
        models: ["image-old"],
        enabled: false
      })

    {:ok, view, _} = live(conn, "/llama/llm/#{provider.id}/edit")

    render_submit(view, "save", %{
      "llm" => %{
        "models_path" => "/llm-models",
        "credential" => "forged",
        "enabled" => "true",
        "provider_id" => Ecto.UUID.generate(),
        "apis" => %{
          "openai" => %{
            "openai_responses" => "true",
            "responses_websocket" => "true",
            "path" => "/v2",
            "default_headers" => ~s({"x-llm":"updated"})
          }
        }
      }
    })

    assert_patch(view, "/llama/llm")

    assert %ProviderApi{
             base_url: "https://api.openai.com/v2",
             enabled: false,
             default_headers: %{"x-llm" => "updated"},
             native_protocols: [:openai_responses],
             responses_websocket: true,
             model_discovery_enabled: false
           } = ProviderApi.get(api.id)

    assert Provider.get(provider.id).credential == "llm-config-key"
    refute Provider.get(provider.id).enabled
    assert %Service{enabled: false, models: ["image-old"]} = Service.get(service.id)
  end

  test "clearing conversation protocols removes only LLM configuration", %{conn: conn} do
    {provider, api} = connection()

    {:ok, api} =
      ProviderApi.update(api, %{
        native_protocols: [:openai_responses],
        responses_websocket: true,
        responses_lifecycle: true,
        model_discovery_enabled: true
      })

    {:ok, service} =
      Service.create(%{provider_id: provider.id, kind: :decisions, models: ["decision-model"]})

    {:ok, view, _} = live(conn, "/llama/llm/#{provider.id}/edit")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "apis" => %{
          "openai" => %{"openai_chat_completions" => "false", "openai_responses" => "false"}
        }
      }
    })
    |> render_submit()

    assert_patch(view, "/llama/llm")
    refute has_element?(view, "#edit-llm-#{provider.id}")

    assert %ProviderApi{
             native_protocols: [],
             enabled: true,
             responses_websocket: false,
             responses_lifecycle: false,
             model_discovery_enabled: false
           } = ProviderApi.get(api.id)

    assert Service.get(service.id).enabled
    assert Provider.get(provider.id).enabled
  end

  test "delete preserves Provider, connection, models, and other APIs", %{conn: conn} do
    {provider, api} = connection()

    {:ok, _} =
      ProviderApi.update(api, %{
        native_protocols: [:openai_responses],
        responses_websocket: true,
        model_discovery_enabled: true
      })

    {:ok, model} = ProviderModel.create(%{provider_id: provider.id, model: "model-a"})

    {:ok, service} =
      Service.create(%{provider_id: provider.id, kind: :images, models: ["image-model"]})

    {:ok, view, _} = live(conn, "/llama/llm")
    assert has_element?(view, "#delete-llm-#{provider.id}[data-confirm][aria-label] svg")

    view |> element("#delete-llm-#{provider.id}") |> render_click()

    refute has_element?(view, "#delete-llm-#{provider.id}")
    assert Provider.get(provider.id).enabled

    assert %ProviderApi{
             native_protocols: [],
             enabled: true,
             responses_websocket: false,
             model_discovery_enabled: false
           } = ProviderApi.get(api.id)

    assert Repo.get!(ProviderModel, model.id).enabled
    assert Service.get(service.id).enabled
  end

  test "selecting a Provider changes only the form draft and Cancel writes nothing", %{
    conn: conn
  } do
    {_provider, api} = connection()

    {other, anthropic} =
      connection(%{name: "other-provider", preset_key: "anthropic", api_surface: :anthropic})

    {:ok, view, _} = live(conn, "/llama/llm/new")

    render_change(view, "select_provider", %{"llm" => %{"provider_id" => other.id}})
    assert has_element?(view, "#llm-anthropic_messages[checked]")
    refute has_element?(view, "#llm-openai-responses-websocket")
    refute has_element?(view, "#llm-openai_responses")
    render_click(view, "cancel")
    assert_patch(view, "/llama/llm")
    refute has_element?(view, "#llm-configuration-page")
    assert ProviderApi.get(api.id).native_protocols == []
    assert ProviderApi.get(anthropic.id).native_protocols == []
  end

  for {preset, surface, credential, protocol} <- [
        {"anthropic", :anthropic, "llm-config-key", :anthropic_messages},
        {"google-gemini-developer", :google, "llm-config-key", :google_generate_content},
        {"google-antigravity", :antigravity, "llm-google-key", :google_antigravity},
        {"openai-codex", :openai, "llm-codex-key", :openai_responses}
      ] do
    test "#{preset} uses its supported conversation protocol defaults", %{conn: conn} do
      {_provider, api} =
        connection(%{
          preset_key: unquote(preset),
          api_surface: unquote(surface),
          credential: unquote(credential)
        })

      {:ok, view, _} = live(conn, "/llama/llm/new")
      assert has_element?(view, "#llm-#{unquote(protocol)}[checked]")

      if unquote(preset) == "openai-codex",
        do: refute(has_element?(view, "#llm-openai_chat_completions"))

      view |> form("#llm-form") |> render_submit()

      assert_patch(view, "/llama/llm")
      assert ProviderApi.get(api.id).native_protocols == [unquote(protocol)]
    end
  end

  test "empty Add state links back to Provider setup and does not create records", %{conn: conn} do
    {:ok, view, _} = live(conn, "/llama/llm/new")
    assert has_element?(view, "#llm-configuration-page", "Configure a Provider connection first")

    assert has_element?(
             view,
             "#llm-configuration-page a[href='/llama/providers']",
             "Manage providers"
           )

    refute has_element?(view, "#llm-form")
    render_click(view, "cancel")
    assert_patch(view, "/llama/llm")
  end

  test "invalid API headers retain the draft and do not write", %{conn: conn} do
    {_provider, api} = connection()
    {:ok, view, _} = live(conn, "/llama/llm/new")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "apis" => %{
          "openai" => %{
            "path" => "/draft/v1",
            "default_headers" => "[]"
          }
        }
      }
    })
    |> render_submit()

    assert has_element?(view, "#llm-errors", "Default Headers must be a JSON object")
    assert has_element?(view, "#llm-openai-path[value='/draft/v1']")
    assert ProviderApi.get(api.id).base_url == "https://api.openai.com/v1"
    assert ProviderApi.get(api.id).default_headers == %{"x-connection" => "preserve"}
  end

  test "protocol-specific URLs and headers stay independent", %{conn: conn} do
    {provider, openai} = connection()

    {:ok, anthropic} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :anthropic,
        base_url: "https://original.example.test/anthropic",
        default_headers: %{"x-other" => "keep"},
        model_discovery_path: "/anthropic-models"
      })

    {:ok, view, _} = live(conn, "/llama/llm/#{provider.id}/edit")

    assert has_element?(view, "#llm-form input[name='llm[models_path]']:only-of-type")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "models_path" => "/models",
        "apis" => %{
          "openai" => %{
            "openai_chat_completions" => "true",
            "path" => "/new/v1",
            "default_headers" => ~s({"x-api":"openai"})
          }
        }
      }
    })
    |> render_submit()

    assert_patch(view, "/llama/llm")
    assert has_element?(view, "#llm-configurations tbody tr:only-child")
    assert has_element?(view, "#llm-configurations tbody", "OpenAI Chat Completions")
    assert has_element?(view, "#llm-configurations .badge-success", "Anthropic Messages")
    assert has_element?(view, "#llm-configurations .badge-neutral", "OpenAI Responses")
    refute has_element?(view, "#llm-configurations th", "Base URL")
    assert has_element?(view, "#llm-configurations tbody code", "/models")
    refute has_element?(view, "#llm-configurations tbody code", "/anthropic-models")
    assert ProviderApi.get(anthropic.id).model_discovery_enabled
    refute ProviderApi.get(openai.id).model_discovery_enabled
    render_patch(view, "/llama/llm/new")
    refute has_element?(view, "#llm-provider option[value='#{provider.id}']")
    assert ProviderApi.get(openai.id).base_url == "https://api.openai.com/new/v1"
    assert ProviderApi.get(openai.id).default_headers == %{"x-api" => "openai"}
    assert ProviderApi.get(anthropic.id).base_url == anthropic.base_url
    assert ProviderApi.get(anthropic.id).default_headers == anthropic.default_headers
  end

  test "shared headers are explicitly configured in LLM and invalid input is atomic", %{
    conn: conn
  } do
    {provider, api} = connection()
    {:ok, view, _} = live(conn, "/llama/llm/new")
    assert has_element?(view, "#llm-provider-default-headers")

    view
    |> form("#llm-form", %{
      "llm" => %{
        "provider_default_headers" => "[]",
        "apis" => %{
          "openai" => %{
            "path" => "/new/v1"
          }
        }
      }
    })
    |> render_submit()

    assert has_element?(view, "#llm-errors", "must be a JSON object")
    assert ProviderApi.get(api.id).base_url == api.base_url

    view
    |> form("#llm-form", %{
      "llm" => %{
        "provider_default_headers" => ~s({"x-shared":"from-llm"})
      }
    })
    |> render_submit()

    assert_patch(view, "/llama/llm")
    assert Provider.get(provider.id).default_headers == %{"x-shared" => "from-llm"}
    assert ProviderApi.get(api.id).base_url == "https://api.openai.com/new/v1"
  end
end
