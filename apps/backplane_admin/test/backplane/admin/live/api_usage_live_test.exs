defmodule Backplane.Admin.ApiUsageLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Admin.Audit
  alias Backplane.Monitor.{ApiAccount, ApiAccounts, ApiUsageServer}
  alias Backplane.Monitor.Providers.{DeepSeek, OpenRouter}
  alias Backplane.Settings.{Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault

  @secret "api-usage-test-secret-never-render"
  @path "/system/monitor/api-usage"

  setup do
    fixtures = %{
      credential: unique("api-key"),
      management: unique("management"),
      excluded_script: unique("excluded-script"),
      excluded_oauth: unique("excluded-oauth")
    }

    options = [
      openrouter_req_options: [plug: {Req.Test, OpenRouter}],
      deepseek_req_options: [plug: {Req.Test, DeepSeek}],
      req_test_owner: self()
    ]

    previous =
      Map.new(options, fn {key, _value} ->
        {key, Application.fetch_env(:backplane_monitor, key)}
      end)

    Enum.each(options, fn {key, value} ->
      Application.put_env(:backplane_monitor, key, value)
    end)

    on_exit(fn ->
      ApiUsageServer.sync([])
      Enum.each(Map.values(fixtures), &Vault.remove/1)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:backplane_monitor, key, value)
        {key, :error} -> Application.delete_env(:backplane_monitor, key)
      end)
    end)

    Req.Test.stub(OpenRouter, fn conn ->
      Req.Test.json(conn, %{"data" => %{"usage" => 0, "limit" => nil}})
    end)

    Req.Test.stub(DeepSeek, fn conn ->
      Req.Test.json(conn, %{
        "is_available" => true,
        "balance_infos" => [
          %{
            "currency" => "USD",
            "total_balance" => "10.00",
            "granted_balance" => "0.00",
            "topped_up_balance" => "10.00"
          }
        ]
      })
    end)

    put_credential(fixtures.credential, "llm")
    {:ok, fixtures}
  end

  test "configuration is a table with credential names, not provider figures or refresh controls",
       %{conn: conn, credential: credential, management: management} do
    put_credential(management, "service")

    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique("configured"),
        provider: "openrouter",
        credential_name: credential,
        management_credential_name: management,
        active: true
      })

    {:ok, view, html} = live(conn, @path)
    assert has_element?(view, "#monitor-api-accounts-table")
    assert html =~ account.name
    assert html =~ credential
    assert html =~ management
    refute html =~ "Account balances"
    refute html =~ "API key spending"
    refute html =~ "Last success"
    refute has_element?(view, "#refresh-all-api-accounts")
    refute has_element?(view, "#refresh-api-account-#{account.id}")
    refute html =~ @secret
  end

  test "configuration index, new and edit render while the usage cache is suspended",
       %{conn: conn, credential: credential} do
    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique("paused"),
        provider: "deepseek",
        credential_name: credential,
        active: false
      })

    cache = Process.whereis(ApiUsageServer)
    :ok = :sys.suspend(cache)

    try do
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#monitor-api-accounts-table")
      render_patch(view, @path <> "/new")
      assert has_element?(view, "#api-account-form")
      render_patch(view, @path <> "/#{account.id}/edit")
      assert has_element?(view, "#api-account-name[value='#{account.name}']")
      view |> form("#api-account-form", account: %{name: account.name}) |> render_change()
      render_patch(view, @path)
      assert has_element?(view, "#monitor-api-accounts-table")
    after
      :ok = :sys.resume(cache)
    end
  end

  test "switching to DeepSeek clears the management credential",
       %{conn: conn, credential: credential, management: management} do
    put_credential(management, "service")

    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique("managed"),
        provider: "openrouter",
        credential_name: credential,
        management_credential_name: management,
        active: true
      })

    {:ok, view, _html} = live(conn, @path <> "/#{account.id}/edit")
    view |> form("#api-account-form", account: %{provider: "deepseek"}) |> render_change()
    refute has_element?(view, "#api-account-management-credential")
    view |> form("#api-account-form") |> render_submit()
    assert_patch(view, @path)
    updated = ApiAccounts.get_account(account.id)
    assert updated.provider == "deepseek"
    assert updated.management_credential_name == nil
  end

  test "System Monitor links API Usage beside Plan Usage", %{conn: conn} do
    {:ok, _view, html} = live(conn, @path)
    assert html =~ "API Usage"
    assert html =~ "No API accounts configured"
    assert html =~ "href=\"/system/monitor/plans\""
    assert html =~ "href=\"#{@path}\""
    refute html =~ @secret
  end

  test "new form lists only eligible vault names and management is OpenRouter-only",
       %{conn: conn, credential: credential, excluded_script: script, excluded_oauth: oauth} do
    put_credential(script, "script")
    put_credential(oauth, "llm", %{"auth_type" => "openai_oauth"})

    {:ok, view, html} = live(conn, @path <> "/new")
    assert html =~ credential
    refute html =~ script
    refute html =~ oauth
    refute html =~ @secret

    view |> form("#api-account-form", account: %{provider: "openrouter"}) |> render_change()
    assert has_element?(view, "#api-account-management-credential")
    view |> form("#api-account-form", account: %{provider: "deepseek"}) |> render_change()
    refute has_element?(view, "#api-account-management-credential")
  end

  test "creates, edits, pauses and deletes with ID-only audit events",
       %{conn: conn, credential: credential} do
    name = unique("account")
    {:ok, view, _} = live(conn, @path <> "/new")

    view
    |> form("#api-account-form",
      account: %{name: name, provider: "deepseek", credential_name: credential, active: true}
    )
    |> render_submit()

    assert_patch(view, @path)
    account = Enum.find(ApiAccounts.list_accounts(), &(&1.name == name))
    assert %ApiAccount{} = account
    assert has_element?(view, "#api-account-#{account.id}")

    view |> element("#edit-api-account-#{account.id}") |> render_click()
    assert_patch(view, @path <> "/#{account.id}/edit")
    view |> form("#api-account-form", account: %{name: name <> " edited"}) |> render_submit()
    assert_patch(view, @path)
    assert ApiAccounts.get_account(account.id).name == name <> " edited"

    view |> element("#toggle-api-account-#{account.id}") |> render_click()
    refute ApiAccounts.get_account(account.id).active
    assert render(view) =~ "Paused"
    dialog_id = "confirm-dialog-delete-api-account-#{account.id}"

    assert has_element?(
             view,
             "#delete-api-account-#{account.id}[command='show-modal'][commandfor='#{dialog_id}']"
           )

    view
    |> element("##{dialog_id} [phx-click='delete'][phx-value-id='#{account.id}']")
    |> render_click()

    assert ApiAccounts.get_account(account.id) == nil
    refute has_element?(view, "#api-account-#{account.id}")

    events = Audit.list(%{target_type: "monitor_api_account", target_id: account.id})

    assert Enum.sort(Enum.map(events, & &1.action)) ==
             Enum.sort([
               "monitor_api_account.create",
               "monitor_api_account.update",
               "monitor_api_account.toggle",
               "monitor_api_account.delete"
             ])

    refute inspect(events) =~ credential
    refute inspect(events) =~ @secret
    refute inspect(events) =~ name
  end

  test "invalid creation stays on the form without recording successful mutations",
       %{conn: conn} do
    {:ok, view, _} = live(conn, @path <> "/new")
    html = view |> form("#api-account-form", account: %{name: ""}) |> render_submit()
    assert html =~ "can&#39;t be blank" or html =~ "can’t be blank"
    assert has_element?(view, "#api-account-form")
    assert Audit.list(%{target_type: "monitor_api_account"}) == []
  end

  test "missing edit target returns to index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: @path}}} =
             live(conn, @path <> "/#{Ecto.UUID.generate()}/edit")
  end

  defp put_credential(name, kind, metadata \\ %{}, secret \\ @secret) do
    Vault.put(%Credential{
      name: name,
      kind: kind,
      metadata: metadata,
      encrypted_value: Encryption.encrypt(secret)
    })
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
