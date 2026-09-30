defmodule Backplane.LLM.CodexCatalogTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{
    CodexCatalog,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  setup do
    credential = "codex-catalog-#{System.unique_integer([:positive])}"
    {:ok, _} = Backplane.Settings.Credentials.store(credential, "catalog-test-key", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "catalog-provider-#{System.unique_integer([:positive])}",
        credential: credential,
        preset_key: "custom"
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://catalog.example.test/v1",
        native_protocols: [:openai_responses]
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "vendor-fast",
        source: :manual,
        display_name: "Vendor Fast",
        metadata: %{
          "context_window" => 100_000,
          "supported_reasoning_levels" => ["low", "high"],
          "default_reasoning_level" => "high"
        }
      })

    {:ok, surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        metadata: %{"context_window" => 120_000}
      })

    %{
      provider: provider,
      api: api,
      model: model,
      source: "#{provider.name}/#{model.model}",
      surface: surface
    }
  end

  test "creates an ordered enabled entry and resolves its public id", %{source: source} do
    {:ok, later} =
      CodexCatalog.create(%{
        public_model_id: "zeta",
        source_model: source,
        priority: 20,
        enabled: true
      })

    {:ok, earlier} =
      CodexCatalog.create(%{
        public_model_id: "alpha",
        source_model: source,
        priority: 10,
        enabled: true
      })

    assert CodexCatalog.target_for("alpha") == source
    ModelResolver.clear_cache()

    assert {:ok, resolved_provider, "vendor-fast"} = ModelResolver.resolve(:openai, "alpha")
    [provider_name, _] = String.split(source, "/", parts: 2)
    assert resolved_provider.name == provider_name
    assert Enum.map(CodexCatalog.list(), & &1.id) == [earlier.id, later.id]
    assert Enum.map(elem(CodexCatalog.response(), 0)["models"], & &1["slug"]) == ["alpha", "zeta"]
  end

  test "rejects duplicate ids and invalid context values", %{source: source} do
    assert {:ok, _} =
             CodexCatalog.create(%{public_model_id: "duplicate", source_model: source})

    assert {:error, changeset} =
             CodexCatalog.create(%{public_model_id: "duplicate", source_model: source})

    assert "has already been taken" in errors_on(changeset).public_model_id

    assert {:error, changeset} =
             CodexCatalog.create(%{
               public_model_id: "invalid-context",
               source_model: source,
               context_window_override: 0
             })

    assert errors_on(changeset).context_window_override != []

    assert {:error, changeset} =
             CodexCatalog.create(%{
               public_model_id: "invalid-priority",
               source_model: source,
               priority: "not-a-number"
             })

    assert errors_on(changeset).priority != []
  end

  test "allows a public id to intentionally match its provider/model target", %{source: source} do
    {:ok, entry} =
      CodexCatalog.create(%{
        public_model_id: source,
        source_model: source,
        enabled: true
      })

    assert entry.public_model_id == source
    assert Enum.map(elem(CodexCatalog.response(), 0)["models"], & &1["slug"]) == [source]
  end

  test "catalog overrides win over canonical and surface metadata", %{source: source} do
    {:ok, entry} =
      CodexCatalog.create(%{
        public_model_id: "public-vendor",
        source_model: source,
        enabled: true,
        context_window_override: 200_000,
        metadata: %{"context_window" => 300_000},
        reasoning_metadata: %{
          "supported_reasoning_levels" => [
            %{"effort" => "deep-research", "description" => "deep"}
          ],
          "default_reasoning_level" => "deep-research"
        }
      })

    assert {:ok, resolved} = CodexCatalog.effective_entry(entry)
    assert resolved.metadata["context_window"] == 200_000
    assert resolved.descriptor["default_reasoning_level"] == "deep-research"

    assert resolved.descriptor["supported_reasoning_levels"] == [
             %{"effort" => "deep-research", "description" => "deep"}
           ]
  end

  test "disabled provider removes an entry from the published response", %{
    provider: provider,
    source: source
  } do
    {:ok, _entry} =
      CodexCatalog.create(%{
        public_model_id: "temporarily-unavailable",
        source_model: source,
        enabled: true
      })

    {:ok, _provider} = Provider.update(provider, %{enabled: false})

    {response, invalid} = CodexCatalog.response()
    assert response == %{"models" => []}
    assert [{%{public_model_id: "temporarily-unavailable"}, :no_provider}] = invalid
  end

  test "an unavailable enabled entry can still be disabled", %{provider: provider, source: source} do
    {:ok, entry} =
      CodexCatalog.create(%{
        public_model_id: "disable-unavailable",
        source_model: source,
        enabled: true
      })

    {:ok, _provider} = Provider.update(provider, %{enabled: false})
    assert {:ok, disabled} = CodexCatalog.toggle(entry)
    refute disabled.enabled
  end

  test "toggle hides and republishes an entry", %{source: source} do
    {:ok, entry} =
      CodexCatalog.create(%{public_model_id: "toggle-me", source_model: source, enabled: true})

    assert length(elem(CodexCatalog.response(), 0)["models"]) == 1

    assert {:ok, disabled} = CodexCatalog.toggle(entry)
    assert disabled.enabled == false
    assert elem(CodexCatalog.response(), 0) == %{"models" => []}

    assert {:ok, _enabled} = CodexCatalog.toggle(disabled)
    assert length(elem(CodexCatalog.response(), 0)["models"]) == 1
  end

  test "updates and deletes a catalog entry", %{source: source} do
    {:ok, entry} =
      CodexCatalog.create(%{public_model_id: "editable", source_model: source, enabled: true})

    assert {:ok, updated} = CodexCatalog.update(entry, %{display_name: "Edited model"})
    assert updated.display_name == "Edited model"

    assert {:ok, deleted} = CodexCatalog.delete(updated)
    assert deleted.id == updated.id
    assert CodexCatalog.get(updated.id) == nil
  end

  test "published public ids route through the Responses proxy", %{api: api, source: source} do
    bypass = Bypass.open()
    {:ok, _api} = ProviderApi.update(api, %{base_url: "http://127.0.0.1:#{bypass.port}/v1"})

    {:ok, _entry} =
      CodexCatalog.create(%{
        public_model_id: "public-vendor",
        source_model: source,
        enabled: true
      })

    Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["model"] == "vendor-fast"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"id":"response-test","output":[]}))
    end)

    response =
      conn(:post, "/v1/responses", Jason.encode!(%{"model" => "public-vendor", "input" => "hi"}))
      |> put_req_header("content-type", "application/json")
      |> Backplane.LLM.Router.call(Backplane.LLM.Router.init([]))

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["id"] == "response-test"
  end
end
