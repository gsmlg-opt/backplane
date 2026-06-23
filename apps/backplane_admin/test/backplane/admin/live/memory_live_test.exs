defmodule Backplane.Admin.MemoryLiveTest do
  use Backplane.Admin.LiveCase

  alias Backplane.Embedding
  alias Backplane.LLM.{Provider, ProviderApi, ProviderModel, ProviderModelSurface}
  alias Backplane.Settings
  alias Backplane.Settings.Credentials
  alias BackplaneMemory.Memory

  describe "GET /admin/memory/browse" do
    test "renders empty state when no memories exist", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/memory/browse")
      assert html =~ "Memories"
      assert has_element?(view, "h1", "Memories")
      assert has_element?(view, ~s|select[name="filters[type]"].select|)
      assert has_element?(view, ~s|input[name="filters[scope]"].input|)
      assert has_element?(view, ~s|input[name="filters[q]"].input|)
      assert render(view) =~ "No memories match"
    end

    test "lists existing memories in a table", %{conn: conn} do
      {:ok, _} =
        Memory.remember("Paris is in France.",
          agent_id: "a",
          host_id: "h",
          type: "semantic",
          scope: "global"
        )

      {:ok, view, html} = live(conn, "/admin/memory/browse")
      assert has_element?(view, "#memories-table")
      assert has_element?(view, ~s|#memories-table th|, "Type")
      assert has_element?(view, ~s|#memories-table th|, "Content")
      assert has_element?(view, ~s|#memories-table th|, "Scope")
      assert html =~ "Paris is in France."
      assert html =~ "semantic"
      assert html =~ "global"
    end

    test "filters by type via URL params", %{conn: conn} do
      {:ok, _} = Memory.remember("alpha", agent_id: "a", host_id: "h", type: "working")
      {:ok, _} = Memory.remember("beta", agent_id: "a", host_id: "h", type: "semantic")

      {:ok, _view, html} = live(conn, "/admin/memory/browse?type=working")
      assert html =~ "alpha"
      refute html =~ "beta"
    end

    test "soft-deletes a memory via the Forget button", %{conn: conn} do
      {:ok, mem} = Memory.remember("forget me", agent_id: "a", host_id: "h")
      {:ok, view, _html} = live(conn, "/admin/memory/browse")

      assert render(view) =~ "forget me"

      view
      |> element(~s|[phx-click="delete"][phx-value-id="#{mem.id}"]|)
      |> render_click()

      refute render(view) =~ "forget me"
      assert {:error, :not_found} = Memory.get(mem.id)
    end
  end

  describe "GET /admin/memory/stats" do
    test "renders type and scope counts", %{conn: conn} do
      Memory.remember("s1", agent_id: "a", host_id: "h", type: "semantic", scope: "alpha")
      Memory.remember("w1", agent_id: "a", host_id: "h", type: "working", scope: "alpha")

      {:ok, _view, html} = live(conn, "/admin/memory/stats")
      assert html =~ "Memory Stats"
      assert html =~ "Semantic"
      assert html =~ "Working"
      assert html =~ "alpha"
    end
  end

  describe "GET /admin/memory/audit" do
    test "renders audit log page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/memory/audit")
      assert html =~ "Audit Log"
      assert has_element?(view, "h1", "Audit Log")
    end
  end

  describe "GET /admin/memory/sessions" do
    test "renders observation sessions page", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/memory/sessions")
      assert html =~ "Sessions"
      assert has_element?(view, "h1", "Sessions")
    end
  end

  describe "GET /admin/memory/config" do
    setup do
      credential = "memory-config-cred-#{System.unique_integer([:positive])}"
      {:ok, _credential} = Credentials.store(credential, "sk-test", "llm")

      :ok = Settings.set("memory.embed_model", nil)
      :ok = Settings.set("memory.llm_model", nil)

      on_exit(fn ->
        Settings.set("memory.embed_model", nil)
        Settings.set("memory.llm_model", nil)
      end)

      {:ok, credential: credential}
    end

    test "renders model selects from llama embedding and LLM provider models", %{
      conn: conn,
      credential: credential
    } do
      embedding_model_id = create_embedding_model(credential)
      llm_model_id = create_llm_model(credential)

      {:ok, view, _html} = live(conn, "/admin/memory/config")

      assert has_element?(view, ~s|select[name="config[memory.embed_model]"]|)

      assert has_element?(
               view,
               ~s|select[name="config[memory.embed_model]"] option[value="#{embedding_model_id}"]|
             )

      assert has_element?(view, ~s|select[name="config[memory.llm_model]"]|)

      assert has_element?(
               view,
               ~s|select[name="config[memory.llm_model]"] option[value="#{llm_model_id}"]|
             )

      refute has_element?(
               view,
               ~s|select[name="config[memory.embed_model]"] option[value="#{llm_model_id}"]|
             )

      refute has_element?(
               view,
               ~s|select[name="config[memory.llm_model]"] option[value="#{embedding_model_id}"]|
             )

      refute has_element?(view, ~s|input[name="config[memory.embed_model]"]|)
      refute has_element?(view, ~s|input[name="config[memory.llm_model]"]|)
      refute render(view) =~ "Embed Enabled"
    end

    test "saves selected embedding and LLM model ids", %{conn: conn, credential: credential} do
      embedding_model_id = create_embedding_model(credential)
      llm_model_id = create_llm_model(credential)

      {:ok, view, _html} = live(conn, "/admin/memory/config")

      html =
        view
        |> form("form", %{
          "config" => %{
            "memory.embed_model" => embedding_model_id,
            "memory.llm_model" => llm_model_id
          }
        })
        |> render_submit()

      assert html =~ "Settings saved."
      assert Settings.get("memory.embed_model") == embedding_model_id
      assert Settings.get("memory.llm_model") == llm_model_id
    end
  end

  defp create_embedding_model(credential) do
    provider_name = "memory-embed-#{System.unique_integer([:positive])}"

    {:ok, _result} =
      Embedding.create_provider_with_model(%{
        "name" => provider_name,
        "credential" => credential,
        "enabled" => "true",
        "base_url" => "https://api.example.com/v1",
        "default_headers" => "{}",
        "model" => "text-embedding-3-small",
        "display_name" => "Text Embedding 3 Small",
        "model_enabled" => "true",
        "metadata" => "{}"
      })

    "#{provider_name}/text-embedding-3-small"
  end

  defp create_llm_model(credential) do
    provider_name = "memory-llm-#{System.unique_integer([:positive])}"

    {:ok, provider} =
      Provider.create(%{
        name: provider_name,
        credential: credential
      })

    {:ok, api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1"
      })

    {:ok, model} =
      ProviderModel.create(%{
        provider_id: provider.id,
        model: "gpt-4o-mini",
        source: :manual,
        enabled: true
      })

    {:ok, _surface} =
      ProviderModelSurface.create(%{
        provider_model_id: model.id,
        provider_api_id: api.id,
        enabled: true
      })

    "#{provider_name}/gpt-4o-mini"
  end
end
