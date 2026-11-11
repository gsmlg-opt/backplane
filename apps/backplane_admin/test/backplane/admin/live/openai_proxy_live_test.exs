defmodule Backplane.Admin.OpenAIProxyLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.Audit
  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.LLM.OpenAI.Service
  alias Backplane.Settings.Credentials

  setup do
    credential = "openai-config-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(credential, "upstream-secret-never-render", "llm")
    {:ok, provider} = Provider.create(%{name: "native-openai", credential: credential})

    {:ok, _} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.openai.com/v1"
      })

    %{provider: provider, credential: credential}
  end

  for {kind, title} <- [
        decisions: "OpenAI Decisions",
        images: "OpenAI Images",
        speech: "OpenAI Text to Speech",
        transcription: "OpenAI Transcription",
        realtime: "OpenAI Realtime"
      ] do
    test "#{kind} has its own configuration menu", %{conn: conn} do
      {:ok, view, html} = live(conn, "/llama/openai/#{unquote(kind)}")
      assert has_element?(view, "h1", unquote(title))
      assert has_element?(view, "#add-openai-service", "Add")
      refute has_element?(view, "#openai-service-form")
      refute has_element?(view, "#openai-service-modal")
      view |> element("#add-openai-service") |> render_click()
      assert has_element?(view, "dialog#openai-service-modal", "Add route")
      assert has_element?(view, "#openai-service-modal #openai-service-form")
      refute has_element?(view, "#openai-service-form [name='service[enabled]']")
      render_click(view, "cancel")
      refute has_element?(view, "#openai-service-modal")
      assert html =~ "LLM Proxy"
      refute html =~ ">API Proxy<"
      refute html =~ "upstream-secret-never-render"
    end
  end

  test "creates, edits, toggles and deletes a capability without changing another", %{
    conn: conn,
    provider: provider,
    credential: credential
  } do
    {:ok, speech} =
      Service.create(%{
        kind: :speech,
        provider_id: provider.id,
        models: ["speech-model"],
        enabled: false
      })

    {:ok, view, _} = live(conn, "/llama/openai/decisions")
    view |> element("#add-openai-service") |> render_click()

    html =
      view |> form("#openai-service-form", %{service: params(provider.id)}) |> render_submit()

    assert html =~ "API proxy configuration saved"
    refute has_element?(view, "#openai-service-modal")
    assert [service] = Service.list(:decisions)
    assert service.models == ["decision-model", "decision-model-2"]
    assert service.default_model == "decision-model"
    assert service.enabled
    assert has_element?(view, "#openai-services-table", "native-openai/decision-model")
    assert html =~ credential
    refute html =~ "upstream-secret-never-render"
    refute Service.get(speech.id).enabled

    assert has_element?(
             view,
             "#toggle-service-#{service.id}[aria-label='Disable native-openai route'] svg"
           )

    view |> element("#toggle-service-#{service.id}") |> render_click()
    refute Service.get(service.id).enabled

    assert has_element?(
             view,
             "#toggle-service-#{service.id}[aria-label='Enable native-openai route'] svg"
           )

    assert has_element?(view, "#edit-service-#{service.id} svg")
    assert has_element?(view, "#delete-service-#{service.id} svg")

    view |> element("#edit-service-#{service.id}") |> render_click()
    assert has_element?(view, "dialog#openai-service-modal", "Edit route")
    refute has_element?(view, "#openai-service-form [name='service[enabled]']")

    view
    |> form("#openai-service-form", %{
      service:
        Map.merge(params(provider.id), %{
          "models_text" => "new-model",
          "default_model" => "new-model"
        })
    })
    |> render_submit()

    refute has_element?(view, "#openai-service-modal")
    assert Service.get(service.id).models == ["new-model"]
    refute Service.get(service.id).enabled
    assert Service.get(speech.id).models == ["speech-model"]
    view |> element("#delete-service-#{service.id}") |> render_click()
    assert Service.list(:decisions) == []

    events = Audit.list()

    assert Enum.sort(Enum.map(events, & &1.action)) ==
             Enum.sort(
               ~w(openai_service.create openai_service.toggle openai_service.update openai_service.delete)
             )

    refute inspect(events) =~ credential
    refute inspect(events) =~ "upstream-secret-never-render"
  end

  test "rejects invalid defaults and keeps submitted values", %{conn: conn, provider: provider} do
    {:ok, view, _} = live(conn, "/llama/openai/images")
    view |> element("#add-openai-service") |> render_click()

    view
    |> form("#openai-service-form", %{
      service: Map.put(params(provider.id), "default_model", "not-allowed")
    })
    |> render_submit()

    assert has_element?(view, "dialog#openai-service-modal")
    assert has_element?(view, "#openai-service-errors", "default_model")
    assert has_element?(view, "input[name='service[default_model]'][value='not-allowed']")
    assert Service.list(:images) == []
    assert Audit.list() == []

    render_click(view, "cancel")
    refute has_element?(view, "#openai-service-modal")
    view |> element("#add-openai-service") |> render_click()
    refute has_element?(view, "#openai-service-errors")
    assert has_element?(view, "input[name='service[default_model]'][value='']")
  end

  test "cancelling an edit leaves the route unchanged and Add opens a fresh form", %{
    conn: conn,
    provider: provider
  } do
    {:ok, service} =
      Service.create(%{kind: :images, provider_id: provider.id, models: ["image-model"]})

    {:ok, view, _} = live(conn, "/llama/openai/images")
    view |> element("#edit-service-#{service.id}") |> render_click()
    assert has_element?(view, "textarea[name='service[models_text]']", "image-model")
    render_click(view, "cancel")
    refute has_element?(view, "#openai-service-modal")
    assert Service.get(service.id).models == ["image-model"]

    view |> element("#add-openai-service") |> render_click()
    assert has_element?(view, "#openai-service-modal", "Add route")
    refute has_element?(view, "textarea[name='service[models_text]']", "image-model")
    assert Audit.list() == []
  end

  test "forged IDs cannot mutate another capability", %{conn: conn, provider: provider} do
    {:ok, service} =
      Service.create(%{kind: :images, provider_id: provider.id, models: ["image-model"]})

    {:ok, view, _} = live(conn, "/llama/openai/decisions")
    render_click(view, "edit", %{"id" => service.id})
    render_click(view, "toggle", %{"id" => service.id})
    render_click(view, "delete", %{"id" => service.id})
    render_click(view, "edit", %{"id" => "invalid-id"})
    assert Service.get(service.id).models == ["image-model"]
    assert Service.get(service.id).enabled
    assert Audit.list() == []
  end

  test "new routes default to enabled and form submissions cannot change enabled state", %{
    conn: conn,
    provider: provider
  } do
    for kind <- Service.kinds() do
      {:ok, view, _} = live(conn, "/llama/openai/#{kind}")
      view |> element("#add-openai-service") |> render_click()

      render_submit(view, "save", %{"service" => Map.put(params(provider.id), "enabled", "false")})

      assert [service] = Service.list(kind)
      assert service.enabled
      view |> element("#toggle-service-#{service.id}") |> render_click()
      refute Service.get(service.id).enabled
      view |> element("#edit-service-#{service.id}") |> render_click()
      render_submit(view, "save", %{"service" => Map.put(params(provider.id), "enabled", "true")})
      refute Service.get(service.id).enabled
      view |> element("#toggle-service-#{service.id}") |> render_click()
      assert Service.get(service.id).enabled
    end
  end

  test "previous API Proxy addresses redirect into Llama", %{conn: conn} do
    assert conn |> get("/api-proxy/audio") |> redirected_to() == "/llama/audio"
    assert conn |> get("/api-proxy/embeddings") |> redirected_to() == "/llama/embedding"

    for kind <- ~w(decisions images speech transcription realtime) do
      assert conn |> get("/api-proxy/openai/#{kind}") |> redirected_to() ==
               "/llama/openai/#{kind}"
    end

    assert conn |> get("/api-proxy/openai/unknown") |> response(404) == "not found"
  end

  defp params(provider_id) do
    %{
      "provider_id" => provider_id,
      "models_text" => "decision-model\ndecision-model-2",
      "default_model" => "decision-model",
      "request_timeout_ms" => "120000",
      "max_request_bytes" => "50000000",
      "max_response_bytes" => "100000000",
      "max_session_ms" => "3600000"
    }
  end
end
