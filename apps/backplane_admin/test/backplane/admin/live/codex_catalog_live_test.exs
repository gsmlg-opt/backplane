defmodule Backplane.Admin.CodexCatalogLiveTest do
  use Backplane.Admin.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{CodexCatalog, Provider, ProviderApi}
  alias Backplane.Settings.Credentials

  @path "/llama/codex-catalog"

  setup do
    previous = Application.fetch_env(:backplane, :llm_model_discovery_req_options)

    Application.put_env(
      :backplane,
      :llm_model_discovery_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:backplane, :llm_model_discovery_req_options, value)
        :error -> Application.delete_env(:backplane, :llm_model_discovery_req_options)
      end
    end)

    :ok
  end

  test "shows import-only controls and no manual catalog editor", %{conn: conn} do
    {:ok, _view, html} = live(conn, @path)

    assert html =~ "Codex Model Catalog"
    assert html =~ ~s(id="codex-provider-import-form")
    assert html =~ "Add and configure an OpenAI Codex provider"
    assert html =~ "No saved Codex models"
    assert html =~ "0 saved"
    assert html =~ "0 published"
    assert html =~ ~s(command="show-modal")
    assert html =~ ~s(commandfor="codex-catalog-preview-dialog")
    refute html =~ ~s(id="codex-catalog-search")
    refute html =~ "Search catalog"
    refute html =~ ~s(id="codex-catalog-form")
    refute html =~ "Routable model candidates"
    refute html =~ "Add model"
  end

  test "offers only configured Codex providers", %{conn: conn} do
    codex = create_codex_provider()
    create_generic_provider()
    {:ok, _view, html} = live(conn, @path)

    assert html =~ codex.name
    assert html =~ ~s(value="#{codex.id}")
    refute html =~ "generic-admin-provider"
  end

  test "refreshes a provider snapshot in one request and retains disabled state", %{
    conn: conn
  } do
    provider = create_codex_provider()
    stub_models([model("gpt-ui-a", "First", 100_000), model("gpt-ui-b", "Second", 200_000)])
    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#codex-provider-import-form", %{"import" => %{"provider_id" => provider.id}})
    |> render_submit()

    html = render_async(view)
    assert html =~ "gpt-ui-a"
    assert html =~ "gpt-ui-b"
    assert html =~ "First"
    assert html =~ "100000"

    entry = Enum.find(CodexCatalog.list(), &(&1.public_model_id == "gpt-ui-a"))
    assert entry.metadata["codex_raw"] == model("gpt-ui-a", "First", 100_000)
    assert entry.source_model == "#{provider.name}/gpt-ui-a"

    view
    |> element(~s([phx-click="toggle"][phx-value-id="#{entry.id}"]))
    |> render_click()

    refute CodexCatalog.get(entry.id).enabled

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :refresh_request)

      Req.Test.json(conn, %{
        "models" => [
          model("gpt-ui-a", "Updated", 120_000),
          model("gpt-ui-b", "Updated second", 220_000),
          model("gpt-ui-c", "New third", 300_000)
        ]
      })
    end)

    assert render(view) =~ "2 saved"
    refute render(view) =~ "refresh-codex-entry-"

    view
    |> element("#refresh-codex-provider-#{provider.id}")
    |> render_click()

    html = render_async(view)
    assert_receive :refresh_request
    refute_receive :refresh_request
    assert html =~ "Updated"
    assert html =~ "120000"
    assert html =~ "Updated second"
    assert html =~ "New third"
    assert html =~ "3 saved"

    assert CodexCatalog.get(entry.id).metadata["codex_raw"] ==
             model("gpt-ui-a", "Updated", 120_000)

    refute CodexCatalog.get(entry.id).enabled
    assert Enum.any?(CodexCatalog.list(), &(&1.public_model_id == "gpt-ui-c"))

    html = render(view)
    assert html =~ "gpt-ui-a"
    assert html =~ "gpt-ui-b"
    assert html =~ "gpt-ui-c"
    assert html =~ "120000"
    assert html =~ ~s(id="refresh-codex-provider-#{provider.id}")

    assert render(view) =~ ~s(command="close")
    view |> element(~s([phx-click="preview"])) |> render_click()
    assert preview_json(view) == Jason.encode!(elem(CodexCatalog.response(), 0), pretty: true)

    second = Enum.find(CodexCatalog.list(), &(&1.public_model_id == "gpt-ui-b"))
    view |> element(~s([phx-click="toggle"][phx-value-id="#{second.id}"])) |> render_click()
    view |> element(~s([phx-click="preview"])) |> render_click()
    assert preview_json(view) == Jason.encode!(elem(CodexCatalog.response(), 0), pretty: true)
    refute preview_json(view) =~ "gpt-ui-b"

    view |> element(~s([phx-click="toggle"][phx-value-id="#{second.id}"])) |> render_click()

    view
    |> element(~s([phx-click="delete"][phx-value-id="#{second.id}"]))
    |> render_click()

    refute CodexCatalog.get(second.id)

    view |> element(~s([phx-click="preview"])) |> render_click()
    assert preview_json(view) == Jason.encode!(elem(CodexCatalog.response(), 0), pretty: true)
    refute preview_json(view) =~ "gpt-ui-b"
  end

  test "provider refresh leaves another provider's models untouched", %{conn: conn} do
    first = create_codex_provider()
    second = create_codex_provider()
    stub_models([model("gpt-first", "First", 100_000)])
    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#codex-provider-import-form", %{"import" => %{"provider_id" => first.id}})
    |> render_submit()

    render_async(view)

    stub_models([model("gpt-second", "Second", 200_000)])

    view
    |> form("#codex-provider-import-form", %{"import" => %{"provider_id" => second.id}})
    |> render_submit()

    render_async(view)
    second_entry = Enum.find(CodexCatalog.list(), &(&1.public_model_id == "gpt-second"))

    stub_models([model("gpt-first", "First updated", 120_000)])
    view |> element("#refresh-codex-provider-#{first.id}") |> render_click()
    assert render_async(view) =~ "First updated"

    assert CodexCatalog.get(second_entry.id).metadata["codex_raw"] ==
             model("gpt-second", "Second", 200_000)

    assert render(view) =~ "2 saved"
    assert render(view) =~ ~s(id="refresh-codex-provider-#{second.id}")
  end

  test "failed refresh keeps all saved models and releases busy", %{conn: conn} do
    provider = create_codex_provider()

    stub_models([
      model("gpt-ui-error", "Before", 100_000),
      model("gpt-ui-other", "Other", 200_000)
    ])

    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#codex-provider-import-form", %{"import" => %{"provider_id" => provider.id}})
    |> render_submit()

    render_async(view)
    before = Map.new(CodexCatalog.list(), &{&1.id, &1.metadata})

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.resp(conn, 503, "upstream-secret-payload")
    end)

    Application.put_env(
      :backplane,
      :llm_model_discovery_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    view
    |> element("#refresh-codex-provider-#{provider.id}")
    |> render_click()

    html = render_async(view, 2_000)
    assert html =~ "saved models were kept"
    refute html =~ "upstream-secret-payload"
    assert html =~ "2 saved"

    assert Map.new(CodexCatalog.list(), &{&1.id, &1.metadata}) == before
    refute html =~ ~s(id="refresh-codex-provider-#{provider.id}" disabled)
  end

  test "busy refresh cannot overlap or mutate an entry", %{conn: conn} do
    provider = create_codex_provider()
    stub_models([model("gpt-ui-busy", "Before", 100_000)])
    {:ok, view, _html} = live(conn, @path)

    view
    |> form("#codex-provider-import-form", %{"import" => %{"provider_id" => provider.id}})
    |> render_submit()

    render_async(view)
    entry = Enum.find(CodexCatalog.list(), &(&1.public_model_id == "gpt-ui-busy"))
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:refresh_started, self()})

      receive do
        :release_refresh ->
          Req.Test.json(conn, %{"models" => [model("gpt-ui-busy", "After", 120_000)]})
      end
    end)

    render_click(view, "refresh_provider", %{"id" => provider.id})
    assert_receive {:refresh_started, request_pid}
    render_click(view, "refresh_provider", %{"id" => provider.id})
    render_click(view, "toggle", %{"id" => entry.id})
    render_click(view, "delete", %{"id" => entry.id})
    refute_receive {:refresh_started, _}
    assert CodexCatalog.get(entry.id).enabled
    send(request_pid, :release_refresh)
    assert render_async(view, 2_000) =~ "After"
  end

  defp preview_json(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#codex-catalog-preview-dialog #codex-catalog-preview")
    |> Floki.text()
  end

  defp stub_models(models) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"models" => models}) end)
  end

  defp model(slug, name, context_window) do
    %{
      "slug" => slug,
      "display_name" => name,
      "context_window" => context_window,
      "supported_reasoning_levels" => [%{"effort" => "low"}, %{"effort" => "high"}]
    }
  end

  defp create_codex_provider do
    credential = "codex-admin-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Credentials.store_device_token(
        credential,
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "test-token",
          "refresh_token" => "refresh-token",
          "expires_at" => System.system_time(:millisecond) + 3_600_000
        },
        %{"account_id" => "acc"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "codex-admin-provider-#{System.unique_integer([:positive])}",
        credential: credential,
        preset_key: "openai-codex"
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://chatgpt.com/backend-api/codex",
        model_discovery_path: "/models",
        native_protocols: [:openai_responses]
      })

    provider
  end

  defp create_generic_provider do
    credential = "generic-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Credentials.store(credential, "test-key", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "generic-admin-provider",
        credential: credential,
        preset_key: "custom"
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://generic.example.test/v1",
        native_protocols: [:openai_responses]
      })

    provider
  end
end
