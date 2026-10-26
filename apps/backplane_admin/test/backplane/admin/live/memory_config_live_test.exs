defmodule Backplane.Admin.MemoryConfigLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Settings
  alias Backplane.Settings.Credentials

  test "embedding selection and readiness use the embedding registry", %{conn: conn} do
    {:ok, _} = Credentials.store("memory-config-embed-credential", "synthetic-upstream", "llm")

    {:ok, %{provider: embedding_provider, model: model}} =
      Backplane.Embedding.create_provider_with_model(%{
        "name" => "memory-config-embed",
        "credential" => "memory-config-embed-credential",
        "base_url" => "https://example.invalid/v1",
        "enabled" => true,
        "model" => "embedding-only",
        "model_enabled" => true,
        "metadata" => ~s({"dimensions":2560})
      })

    {:ok, provider} =
      Backplane.LLM.Provider.create(%{
        name: "memory-config-llm-only",
        credential: "memory-config-embed-credential"
      })

    {:ok, api} =
      Backplane.LLM.ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://example.invalid/v1"
      })

    {:ok, llm_model} =
      Backplane.LLM.ProviderModel.create(%{
        provider_id: provider.id,
        model: "llm-only",
        source: :manual
      })

    {:ok, _} =
      Backplane.LLM.ProviderModelSurface.create(%{
        provider_model_id: llm_model.id,
        provider_api_id: api.id
      })

    embedding_id = Backplane.Embedding.model_id(%{model | provider: embedding_provider})
    embedding_keys = ~w(memory.embed_model)
    llm_id = "memory-config-llm-only/llm-only"

    for key <- embedding_keys, do: :ets.insert(:backplane_settings, {key, embedding_id})
    :ets.insert(:backplane_settings, {"memory.recall_relevance_vector_model", "retired-model"})

    {:ok, view, _} = live(conn, "/memory/config?q=Embedding+model")
    refute has_element?(view, "option[value='memory-config-llm-only/llm-only']")
    refute has_element?(view, "#memory-config-value-memory-recall_relevance_vector_model")
    refute has_element?(view, "option[value='retired-model']")

    for key <- embedding_keys do
      id = String.replace(key, ".", "-")
      selector = "#memory-config-value-#{id}"
      assert has_element?(view, "#{selector} option[value='#{embedding_id}']", embedding_id)
      refute has_element?(view, "#{selector} option[value='#{embedding_id}']", "unavailable")
      refute has_element?(view, "#{selector} option[value='#{llm_id}']")
      assert has_element?(view, "#route-#{id}", "Route resolved: memory-config-embed")
      assert has_element?(view, "#route-#{id}", "request health unverified")
    end

    for key <- embedding_keys do
      id = String.replace(key, ".", "-")

      render_submit(view, "set-setting", %{"setting" => %{"key" => key, "value" => llm_id}})

      assert Settings.get(key) == llm_id
      assert has_element?(view, "#route-#{id}", "no enabled embedding provider route")

      assert has_element?(
               view,
               "#memory-config-value-#{id} option[value='#{llm_id}']",
               "unavailable"
             )
    end

    render_change(view, "filter", %{"filters" => %{"q" => "model"}})

    for key <- ~w(memory.llm_model memory.recall_relevance_reranker_model) do
      id = String.replace(key, ".", "-")
      selector = "#memory-config-value-#{id}"
      assert has_element?(view, "#{selector} option[value='#{llm_id}']", llm_id)
      refute has_element?(view, "#{selector} option[value='#{llm_id}']", "unavailable")
      refute has_element?(view, "#{selector} option[value='#{embedding_id}']")

      render_submit(view, "set-setting", %{"setting" => %{"key" => key, "value" => llm_id}})

      assert Settings.get(key) == llm_id
      assert has_element?(view, "#route-#{id}", "Route resolved: memory-config-llm-only")
      assert has_element?(view, "#route-#{id}", "request health unverified")
    end
  end

  setup do
    snapshot = :ets.tab2list(:backplane_settings)

    on_exit(fn ->
      :ets.delete_all_objects(:backplane_settings)
      :ets.insert(:backplane_settings, snapshot)
    end)

    :ok
  end

  test "configuration exposes one current control for each memory capability", %{conn: conn} do
    {:ok, view, html} = live(conn, "/memory/config")
    tree = Floki.parse_fragment!(html)

    for key <- ~w(host_sync recall session_summary fact_extraction procedure_extraction) do
      assert length(Floki.find(tree, "#memory-config-value-memory-#{key}-enabled")) == 1
    end

    for key <-
          ~w(host_sync_v1 host_sync_v2 recall_v2 session_summary_v2 fact_extraction_v2 procedure_extraction_v2) do
      refute has_element?(view, "#memory-config-value-memory-#{key}-enabled")
    end

    refute html =~ "Host sync V1"
    refute html =~ "Host sync V2"
    refute html =~ "Recall V2"
  end

  test "model readiness is explicit and unavailable selected models remain visible", %{conn: conn} do
    :ets.insert(:backplane_settings, {"memory.llm_model", "missing-provider/model"})
    {:ok, view, _} = live(conn, "/memory/config?q=Processing+model")
    assert has_element?(view, "#route-memory-llm_model", "no enabled OpenAI-compatible")
    assert has_element?(view, "option[value='missing-provider/model']", "unavailable")
    assert render(view) =~ "persisted across restart"

    render_submit(view, "set-setting", %{
      "setting" => %{"key" => "memory.llm_model", "value" => ""}
    })

    assert Settings.get("memory.llm_model") == nil
    assert render(view) =~ "No model selected"
  end

  test "credential selector includes safe service names and never secrets or provider keys", %{
    conn: conn
  } do
    suffix = System.unique_integer([:positive])
    service = "memory-resource-#{suffix}"
    provider = "memory-provider-#{suffix}"
    assert {:ok, _} = Credentials.store(service, "private-test-resource-secret", "service")
    assert {:ok, _} = Credentials.store(provider, "private-test-provider-secret", "llm")
    {:ok, view, html} = live(conn, "/memory/config?q=Gateway+resource")
    assert has_element?(view, "option[value='#{service}']")
    refute has_element?(view, "option[value='#{provider}']")
    refute html =~ "private-test-resource-secret"
    refute html =~ "private-test-provider-secret"

    render_submit(view, "set-setting", %{
      "setting" => %{"key" => "memory.proxy_credential", "value" => service}
    })

    assert Settings.get("memory.proxy_credential") == service
  end

  test "configured stage explains disabled parent and live service discovery", %{conn: conn} do
    :ets.insert(:backplane_settings, {"memory.pipeline.enabled", false})
    :ets.insert(:backplane_settings, {"memory.fact_extraction.enabled", true})
    {:ok, view, _} = live(conn, "/memory/config?q=Fact+extraction")
    assert render(view) =~ "Blocked: processing pipeline disabled"
    assert has_element?(view, "#memory-config-value-memory-fact_extraction-enabled")
    render_change(view, "filter", %{"filters" => %{"q" => "Memory service"}})
    assert render(view) =~ "Live; updates tool and prompt discovery"
  end
end
