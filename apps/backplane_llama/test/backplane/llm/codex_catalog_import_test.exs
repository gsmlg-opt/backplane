defmodule Backplane.LLM.CodexCatalogImportTest do
  use BackplaneLlama.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.LLM.{
    CodexCatalog,
    CodexCatalogEntry,
    ModelResolver,
    Provider,
    ProviderApi,
    ProviderModel,
    Router
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  setup do
    previous = Application.get_env(:backplane, :llm_model_discovery_req_options)

    Application.put_env(:backplane, :llm_model_discovery_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane, :llm_model_discovery_req_options, previous),
        else: Application.delete_env(:backplane, :llm_model_discovery_req_options)
    end)

    credential = "catalog-import-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Credentials.store_device_token(
        credential,
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "catalog-access-token",
          "refresh_token" => "catalog-refresh-token",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "catalog-account"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "catalog-codex-#{System.unique_integer([:positive])}",
        preset_key: "openai-codex",
        credential: credential
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex",
        model_discovery_path: "/models",
        native_protocols: [:openai_responses]
      })

    %{provider: provider, api: api}
  end

  test "imports every exact upstream descriptor and makes raw slugs routable", %{
    provider: provider
  } do
    first = descriptor("gpt-catalog-a", %{"unknown_capability" => %{"nested" => [1, 2]}})
    second = descriptor("gpt-catalog-b", %{"visibility" => "hide"})
    stub_models([first, second])

    assert Enum.any?(CodexCatalog.providers(), &(&1.id == provider.id))

    assert {:ok, %{created: 2, refreshed: 0, retained: 0}} =
             CodexCatalog.import_provider(provider.id)

    assert Enum.map(CodexCatalog.list(), & &1.public_model_id) ==
             ["gpt-catalog-a", "gpt-catalog-b"]

    assert %{"codex_raw" => ^first} =
             Repo.get_by!(CodexCatalogEntry, public_model_id: "gpt-catalog-a").metadata

    assert {%{"models" => models}, []} = CodexCatalog.response()
    assert models == [first, second]
    assert ProviderModel.get_by_provider_and_model(provider.id, "gpt-catalog-a")
    assert {:ok, resolved, "gpt-catalog-a"} = ModelResolver.resolve(:openai, "gpt-catalog-a")
    assert resolved.id == provider.id
  end

  test "refreshes only the selected saved descriptor and preserves disabled state", %{
    provider: provider
  } do
    first = descriptor("gpt-catalog-a")
    second = descriptor("gpt-catalog-b")
    stub_models([first, second])
    assert {:ok, %{created: 2}} = CodexCatalog.import_provider(provider.id)

    entry = Repo.get_by!(CodexCatalogEntry, public_model_id: "gpt-catalog-a")
    assert {:ok, disabled} = CodexCatalog.toggle(entry)
    refute disabled.enabled

    updated_first = descriptor("gpt-catalog-a", %{"new_property" => true})
    updated_second = descriptor("gpt-catalog-b", %{"new_property" => true})
    stub_models([updated_first, updated_second])

    assert {:ok, refreshed} = CodexCatalog.refresh(entry.id)
    refute refreshed.enabled
    assert refreshed.metadata["codex_raw"] == updated_first

    assert Repo.get_by!(CodexCatalogEntry, public_model_id: "gpt-catalog-b").metadata[
             "codex_raw"
           ] == second
  end

  test "reimport retains unchanged rows and an operator-disabled entry", %{provider: provider} do
    first = descriptor("gpt-catalog-a")
    second = descriptor("gpt-catalog-b")
    stub_models([first, second])

    assert {:ok, %{created: 2, refreshed: 0, retained: 0}} =
             CodexCatalog.import_provider(provider.id)

    entry = Repo.get_by!(CodexCatalogEntry, public_model_id: "gpt-catalog-a")
    assert {:ok, disabled} = CodexCatalog.toggle(entry)
    refute disabled.enabled

    stub_models([first, second])

    assert {:ok, %{created: 0, refreshed: 0, retained: 2}} =
             CodexCatalog.import_provider(provider.id)

    assert length(CodexCatalog.list()) == 2
    assert CodexCatalog.get(entry.id).enabled == false
  end

  test "failed, empty, and missing-model refresh retain the saved snapshot", %{
    provider: provider
  } do
    first = descriptor("gpt-catalog-a")
    second = descriptor("gpt-catalog-b")
    stub_models([first, second])
    assert {:ok, _} = CodexCatalog.import_provider(provider.id)
    entry = Repo.get_by!(CodexCatalogEntry, public_model_id: "gpt-catalog-a")

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"models" => []}) end)
    assert {:error, %{errors: [_]}} = CodexCatalog.refresh(entry.id)
    assert CodexCatalog.get(entry.id).metadata["codex_raw"] == first

    Req.Test.stub(__MODULE__, fn conn -> send_resp(conn, 503, "unavailable") end)
    assert {:error, %{errors: [_]}} = CodexCatalog.refresh(entry.id)
    assert CodexCatalog.get(entry.id).metadata["codex_raw"] == first

    stub_models([second])
    assert {:error, :model_unavailable} = CodexCatalog.refresh(entry.id)
    assert CodexCatalog.get(entry.id).metadata["codex_raw"] == first
    assert CodexCatalog.target_for("gpt-catalog-a") == nil
  end

  test "a slug conflict rolls back the entire catalog batch", %{provider: provider} do
    first = descriptor("gpt-catalog-a")
    second = descriptor("gpt-catalog-b")

    Repo.insert!(%CodexCatalogEntry{
      public_model_id: second["slug"],
      source_model: "another-provider/#{second["slug"]}",
      metadata: %{"codex_raw" => second},
      enabled: false
    })

    stub_models([first, second])

    assert {:error, {:model_conflict, "gpt-catalog-b"}} =
             CodexCatalog.import_provider(provider.id)

    refute Repo.get_by(CodexCatalogEntry, public_model_id: first["slug"])

    assert Repo.get_by!(CodexCatalogEntry, public_model_id: second["slug"]).source_model ==
             "another-provider/gpt-catalog-b"
  end

  test "refresh returns a safe error if the saved entry is deleted during discovery", %{
    provider: provider
  } do
    stub_models([descriptor("gpt-catalog-a")])
    assert {:ok, _} = CodexCatalog.import_provider(provider.id)
    entry = Repo.get_by!(CodexCatalogEntry, public_model_id: "gpt-catalog-a")

    Req.Test.stub(__MODULE__, fn conn ->
      assert {:ok, _} = CodexCatalog.delete(entry)
      Req.Test.json(conn, %{"models" => [descriptor("gpt-catalog-a")]})
    end)

    assert {:error, :invalid_codex_entry} = CodexCatalog.refresh(entry.id)
    refute CodexCatalog.get(entry.id)
  end

  test "non-Codex providers and legacy catalog rows cannot be published", %{
    provider: provider
  } do
    raw = descriptor("gpt-catalog-a")
    stub_models([raw])
    assert {:ok, _} = CodexCatalog.import_provider(provider.id)

    {:ok, other} =
      Provider.create(%{
        name: "catalog-custom-#{System.unique_integer([:positive])}",
        credential: provider.credential,
        preset_key: "custom"
      })

    refute Enum.any?(CodexCatalog.providers(), &(&1.id == other.id))
    assert {:error, :invalid_codex_provider} = CodexCatalog.import_provider(other.id)

    legacy =
      Repo.insert!(%CodexCatalogEntry{
        public_model_id: "legacy-generic",
        source_model: "#{other.name}/old",
        enabled: true
      })

    assert {:error, _} = CodexCatalog.effective_entry(legacy)
    assert CodexCatalog.target_for("legacy-generic") == nil
  end

  test "saved raw slug invokes the selected Codex provider through Responses", %{
    provider: provider,
    api: api
  } do
    raw = descriptor("gpt-catalog-a")
    stub_models([raw])
    assert {:ok, _} = CodexCatalog.import_provider(provider.id)

    bypass = Bypass.open()

    {:ok, _} =
      ProviderApi.update(api, %{base_url: "http://127.0.0.1:#{bypass.port}/backend-api/codex"})

    Bypass.expect_once(bypass, "POST", "/backend-api/codex/responses", fn conn ->
      {:ok, body, conn} = read_body(conn)
      assert Jason.decode!(body)["model"] == "gpt-catalog-a"
      assert ["Bearer catalog-access-token"] = get_req_header(conn, "authorization")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"id":"response-test","output":[]}))
    end)

    conn =
      conn(:post, "/v1/responses", Jason.encode!(%{"model" => "gpt-catalog-a", "input" => "hi"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
  end

  defp descriptor(slug, extra \\ %{}) do
    Map.merge(
      %{
        "slug" => slug,
        "display_name" => "Display #{slug}",
        "description" => "From Codex",
        "priority" => 3,
        "context_window" => 123_456,
        "supported_reasoning_levels" => [%{"effort" => "high", "description" => "High"}]
      },
      extra
    )
  end

  defp stub_models(models) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/backend-api/codex/models"
      assert ["Bearer catalog-access-token"] = get_req_header(conn, "authorization")
      assert ["catalog-account"] = get_req_header(conn, "chatgpt-account-id")
      Req.Test.json(conn, %{"models" => models})
    end)
  end
end
