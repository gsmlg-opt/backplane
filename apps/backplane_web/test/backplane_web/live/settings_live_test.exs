defmodule BackplaneWeb.AdminSettingsSplitLiveTest do
  use Backplane.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias Backplane.LLM.{
    AutoModel,
    AutoModelRoute,
    Provider,
    ProviderApi,
    ProviderModel,
    ProviderModelSurface
  }

  alias Backplane.Repo
  alias Backplane.Settings.Credentials

  describe "settings tab" do
    setup do
      reset_auto_model_targets()
      reset_custom_model_aliases()
      :ok
    end

    test "renders model alias settings instead of internal service toggles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/llama/model-aliases")

      assert html =~ "Model Aliases"
      assert html =~ "smart"
      assert html =~ "fast"
      assert html =~ "expert"
      assert html =~ "No target models selected"
      refute html =~ "minimax-m2.7"
      refute html =~ "kimi-k2.6"
      refute html =~ "glm-5.1"

      refute html =~ "services.day.enabled"
      refute html =~ "services.web.enabled"
      refute html =~ "admin.auth_enabled"
      refute html =~ "mcp.auth_required"
    end

    test "renders model aliases in fast, smart, expert order", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/llama/model-aliases")

      fast_index = index_of!(html, "auto-model-fast-add-form")
      smart_index = index_of!(html, "auto-model-smart-add-form")
      expert_index = index_of!(html, "auto-model-expert-add-form")

      assert fast_index < smart_index
      assert smart_index < expert_index
    end

    test "renders target model picker options from enabled provider models", %{conn: conn} do
      create_provider_models(["fast-model-a"])

      {:ok, _view, html} = live(conn, "/admin/llama/model-aliases")

      assert html =~ ~s(id="auto-model-fast-model")
      assert html =~ ~s(<option value="fast-model-a">)
      refute html =~ ~s(id="auto-model-fast-models")
    end

    test "adds selected model target to alias list", %{conn: conn} do
      {openai_api, [model_id]} = create_provider_models(["fast-model-a"])

      {:ok, view, _html} = live(conn, "/admin/llama/model-aliases")

      html =
        view
        |> form("#auto-model-fast-add-form", %{
          "name" => "fast",
          "model" => model_id
        })
        |> render_submit()

      assert html =~ model_id
      assert AutoModel.configured_model_ids("fast") == [model_id]

      route = AutoModelRoute.get_by_model_and_surface("fast", :openai)

      targets =
        route.targets
        |> Enum.sort_by(& &1.priority)
        |> Enum.map(& &1.provider_model_surface_id)

      expected_targets =
        ProviderModel
        |> Repo.get_by!(provider_id: openai_api.provider_id, model: model_id)
        |> then(&ProviderModelSurface.get_by_model_and_api(&1.id, openai_api.id))
        |> Map.fetch!(:id)

      assert targets == [expected_targets]
    end

    test "removes a model target from the alias list", %{conn: conn} do
      {_openai_api, [model_id]} = create_provider_models(["fast-model-a"])

      {:ok, view, _html} = live(conn, "/admin/llama/model-aliases")

      view
      |> form("#auto-model-fast-add-form", %{
        "name" => "fast",
        "model" => model_id
      })
      |> render_submit()

      html =
        view
        |> element(
          ~s(button[phx-click="remove_auto_model_target"][phx-value-name="fast"][phx-value-model="#{model_id}"])
        )
        |> render_click()

      assert html =~ "No target models selected"
      assert AutoModel.configured_model_ids("fast") == []
    end

    test "renders custom alias form with built-in alias targets", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/llama/model-aliases")

      assert html =~ ~s(id="custom-model-alias-form")
      assert html =~ ~s(id="custom-model-alias-target")
      assert html =~ ~s(<option value="fast">)
      assert html =~ ~s(<option value="smart">)
      assert html =~ ~s(<option value="expert">)
    end

    test "adds custom alias pointing to a built-in alias", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/llama/model-aliases")

      html =
        view
        |> form("#custom-model-alias-form", %{
          "alias" => "coding",
          "target" => "expert"
        })
        |> render_submit()

      assert html =~ "coding"
      assert html =~ "expert"
      assert [%{alias: "coding", target: "expert"}] = Backplane.LLM.ModelAlias.list()
    end

    test "removes a custom alias", %{conn: conn} do
      {:ok, _alias} = Backplane.LLM.ModelAlias.put("coding", "smart")

      {:ok, view, _html} = live(conn, "/admin/llama/model-aliases")

      html =
        view
        |> element(~s(button[phx-click="remove_custom_model_alias"][phx-value-alias="coding"]))
        |> render_click()

      assert html =~ "No custom aliases configured"
      assert Backplane.LLM.ModelAlias.list() == []
    end
  end

  defp reset_auto_model_targets do
    :ok = Backplane.Settings.set("llm.auto_models.fast.targets", [])
    :ok = Backplane.Settings.set("llm.auto_models.smart.targets", [])
    :ok = Backplane.Settings.set("llm.auto_models.expert.targets", [])
  end

  defp reset_custom_model_aliases do
    :ok = Backplane.Settings.set("llm.model_aliases.custom", %{})
  end

  defp create_provider_models(model_ids) do
    credential = "settings-llm-#{System.unique_integer([:positive])}"
    Credentials.store(credential, "sk-test", "llm")

    {:ok, provider} =
      Provider.create(%{
        name: "settings-provider-#{System.unique_integer([:positive])}",
        credential: credential
      })

    {:ok, openai_api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "https://api.example.com/v1"
      })

    for model_id <- model_ids do
      {:ok, model} =
        ProviderModel.create(%{
          provider_id: provider.id,
          model: model_id,
          source: :manual
        })

      {:ok, _surface} =
        ProviderModelSurface.create(%{
          provider_model_id: model.id,
          provider_api_id: openai_api.id,
          enabled: true
        })
    end

    {openai_api, model_ids}
  end

  defp index_of!(html, value) do
    case :binary.match(html, value) do
      {index, _length} -> index
      :nomatch -> flunk("expected #{inspect(value)} to be present in rendered HTML")
    end
  end

  describe "credentials tab" do
    setup do
      {:ok, pid} =
        Bandit.start_link(
          plug: BackplaneWeb.AdminSettingsSplitLiveTest.DeviceAuthMockEndpoint,
          port: 0
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

      prior = Application.get_env(:backplane, Backplane.Settings.OpenAICodexAuth, [])

      Application.put_env(:backplane, Backplane.Settings.OpenAICodexAuth,
        device_user_code_url: "http://localhost:#{port}/api/accounts/deviceauth/usercode",
        device_token_url: "http://localhost:#{port}/api/accounts/deviceauth/token",
        token_url: "http://localhost:#{port}/oauth/token",
        revoke_url: "http://localhost:#{port}/oauth/revoke"
      )

      on_exit(fn ->
        Application.put_env(:backplane, Backplane.Settings.OpenAICodexAuth, prior)

        try do
          ThousandIsland.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok
    end

    test "renders credentials tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/system/credentials")
      assert html =~ "Credential Store"
      assert html =~ "Add Credential"
    end

    test "clicking Add Credential patches the URL to the new form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system/credentials")

      html =
        view
        |> element("a[href=\"/admin/system/credentials/new\"]")
        |> render_click()

      assert_patched(view, "/admin/system/credentials/new")
      assert html =~ "New Credential"
      assert html =~ "save_credential"
    end

    test "can add a credential", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system/credentials")

      # Open the form via patching
      view
      |> element("a[href=\"/admin/system/credentials/new\"]")
      |> render_click()

      # Submit the form
      html =
        view
        |> form("form[phx-submit=save_credential]", %{
          "name" => "test-key",
          "kind" => "llm",
          "secret" => "sk-test-123"
        })
        |> render_submit()

      assert_patched(view, "/admin/system/credentials")
      assert html =~ "test-key"
      refute html =~ "New Credential"
    end

    test "clicking Connect Claude Plan patches the URL to the oauth form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system/credentials")

      html =
        view
        |> element("a[href=\"/admin/system/credentials/new/anthropic_oauth\"]")
        |> render_click()

      assert_patched(view, "/admin/system/credentials/new/anthropic_oauth")
      assert html =~ "Connect Claude Plan"
    end

    test "submitting device auth form for OpenAI requests device code and polls", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system/credentials/new/openai_oauth")

      html =
        view
        |> form("form[phx-submit=start_device_auth]", %{
          "cred_name" => "my-openai-codex"
        })
        |> render_submit()

      assert html =~ "Follow these steps to sign in with ChatGPT"
      assert html =~ "https://auth.openai.com/codex/device"
      assert html =~ "LNKB-13LTY"

      login = %{
        device_auth_id: "mock-device-auth-id",
        user_code: "LNKB-13LTY",
        interval_seconds: 1,
        expires_at: System.system_time(:millisecond) + 60_000
      }

      send(view.pid, {:poll_openai_codex_auth, login, "my-openai-codex"})

      render(view)

      assert_patched(view, "/admin/system/credentials")
      assert render(view) =~ "my-openai-codex"
    end

    test "submitting Google auth form without client config shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system/credentials/new/google_oauth")

      html =
        view
        |> form("form[phx-submit=start_device_auth]", %{
          "cred_name" => "my-google-ai"
        })
        |> render_submit()

      assert html =~ "Authorization is not configured"
      assert html =~ "missing_google_oauth_client_id"
    end

    test "can add a script credential with textarea content and ignoring auth type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/system/credentials")

      view
      |> element("a[href=\"/admin/system/credentials/new\"]")
      |> render_click()

      html = render(view)
      assert html =~ "<option value=\"script\">"

      html =
        view
        |> element("#cred-kind")
        |> render_change(%{"kind" => "script"})

      assert html =~ "<textarea"
      refute html =~ "Auth Type"

      html =
        view
        |> form("form[phx-submit=save_credential]", %{
          "name" => "my-script-key",
          "kind" => "script",
          "secret" => "echo 'hello world'"
        })
        |> render_submit()

      assert_patched(view, "/admin/system/credentials")
      assert html =~ "my-script-key"

      assert {:ok, "echo 'hello world'"} = Credentials.fetch("my-script-key")
      assert {:ok, _, %{auth_type: "api_key"}} = Credentials.fetch_with_meta("my-script-key")
    end
  end
end

defmodule BackplaneWeb.AdminSettingsSplitLiveTest.DeviceAuthMockEndpoint do
  use Plug.Router
  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)
  plug(:dispatch)

  post "/api/accounts/deviceauth/usercode" do
    resp = %{
      "device_auth_id" => "mock-device-auth-id",
      "user_code" => "LNKB-13LTY",
      "interval" => "1"
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(resp))
  end

  post "/api/accounts/deviceauth/token" do
    resp = %{
      "authorization_code" => "mock-authorization-code",
      "code_challenge" => "mock-code-challenge",
      "code_verifier" => "mock-code-verifier"
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(resp))
  end

  post "/oauth/token" do
    resp = %{
      "id_token" =>
        jwt(%{
          "chatgpt_account_id" => "mock-account-id",
          "chatgpt_plan_type" => "plus",
          "exp" => 1_900_000_000
        }),
      "access_token" => "mock-access-token",
      "refresh_token" => "mock-refresh-token",
      "token_type" => "Bearer"
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(resp))
  end

  post "/oauth/revoke" do
    send_resp(conn, 200, "{}")
  end

  defp jwt(payload) do
    encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded_payload}.sig"
  end
end
