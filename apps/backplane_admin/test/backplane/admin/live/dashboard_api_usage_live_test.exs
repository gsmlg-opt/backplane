defmodule Backplane.Admin.DashboardApiUsageLiveTest do
  use Backplane.Admin.LiveCase, async: false

  alias Backplane.Monitor.{ApiAccounts, ApiUsageServer}
  alias Backplane.Monitor.Providers.{DeepSeek, OpenAI, OpenRouter}
  alias Backplane.Settings.{Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault

  @secret "api-usage-test-secret-never-render"
  @path "/dashboard/usage/api"

  setup do
    previous_enabled = ApiAccounts.fetching_enabled?()
    :ok = ApiAccounts.set_fetching_enabled(true)

    fixtures = %{
      credential: unique("api-key"),
      management: unique("management")
    }

    options = [
      openrouter_http_options: [adapter: {HTTP.Test, OpenRouter}],
      deepseek_http_options: [adapter: {HTTP.Test, DeepSeek}],
      openai_http_options: [adapter: {HTTP.Test, OpenAI}],
      http_test_owner: self()
    ]

    previous =
      Map.new(options, fn {key, _value} ->
        {key, Application.fetch_env(:backplane_monitor, key)}
      end)

    Enum.each(options, fn {key, value} ->
      Application.put_env(:backplane_monitor, key, value)
    end)

    on_exit(fn ->
      :ets.insert(:backplane_settings, {"monitor.api_usage.enabled", previous_enabled})
      :ok = ApiUsageServer.reload_fetching_policy()
      ApiUsageServer.sync([])
      Enum.each(Map.values(fixtures), &Vault.remove/1)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:backplane_monitor, key, value)
        {key, :error} -> Application.delete_env(:backplane_monitor, key)
      end)
    end)

    HTTP.Test.stub(OpenRouter, fn _request ->
      HTTP.Test.json(%{"data" => %{"usage" => 0, "limit" => nil}})
    end)

    HTTP.Test.stub(DeepSeek, fn _request ->
      HTTP.Test.json(%{
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

  test "dashboard links account management without configuration controls", %{conn: conn} do
    {:ok, view, html} = live(conn, @path)
    assert html =~ "No API accounts configured"
    assert has_element?(view, "a[href='/system/monitor/api-usage']", "Manage API Accounts")
    refute has_element?(view, "#api-account-form")
    refute html =~ @secret
  end

  test "OpenAI displays organization spending, token units, and pending balance support",
       %{conn: conn, credential: credential} do
    HTTP.Test.stub(OpenAI, fn request ->
      assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer #{@secret}"]
      assert HTTP.Headers.get_all(request.headers, "openai-organization") == ["org-primary"]
      openai_response(request)
    end)

    account = create_openai_account(credential, "org-primary")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil and not &1.refreshing))
    {:ok, view, html} = live(conn, @path)
    assert has_element?(view, "#api-account-#{account.id}", "OpenAI Platform")
    assert html =~ "org-primary"
    assert html =~ "Organization spending (today, UTC)"
    assert html =~ "Organization spending (month to date, UTC)"
    assert html =~ "1.25 USD"
    assert html =~ "Input tokens (today, UTC)"
    assert html =~ "100 tokens"
    assert html =~ "20 tokens"
    assert html =~ "10 tokens"
    assert html =~ "3 requests"
    assert html =~ "Completions usage"
    assert html =~ "Spending covers the whole organization"
    assert html =~ "Unavailable — public API balance support pending."

    assert has_element?(
             view,
             "a[href='https://platform.openai.com/settings/organization/billing/overview']"
           )

    refute html =~ "100 USD"
    refute html =~ "Purchased credits"
    refute html =~ @secret
  end

  test "OpenAI organization selection deduplicates IDs and keeps other providers visible",
       %{conn: conn, credential: credential} do
    :ok = ApiAccounts.set_fetching_enabled(false)
    first = create_openai_account(credential, "org-first", false)
    second = create_openai_account(credential, "org-second", false)
    duplicate = create_openai_account(credential, "org-first", false)
    other = create_account(credential, "deepseek")

    {:ok, view, html} = live(conn, @path)
    assert html =~ "Unavailable — public API balance support pending."
    refute html =~ "0 USD"

    assert html
           |> Floki.parse_fragment!()
           |> Floki.find("#api-usage-organization option[value='org-first']")
           |> length() == 1

    view
    |> form("#api-organization-filter", organization_id: "org-first")
    |> render_change()

    assert has_element?(view, "#api-account-#{first.id}")
    assert has_element?(view, "#api-account-#{duplicate.id}")
    assert has_element?(view, "#api-account-#{other.id}")
    refute has_element?(view, "#api-account-#{second.id}")

    view
    |> form("#api-organization-filter", organization_id: "org-second")
    |> render_change()

    assert has_element?(view, "#api-account-#{second.id}")
    refute has_element?(view, "#api-account-#{first.id}")
    {:ok, _deleted} = ApiAccounts.delete_account(second)
    send(view.pid, :reload_states)
    render(view)
    assert has_element?(view, "#api-account-#{first.id}")
    assert has_element?(view, "#api-account-#{duplicate.id}")
    assert has_element?(view, "#api-account-#{other.id}")
    refute has_element?(view, "#api-usage-organization option[value='org-second']")

    render_change(view, "select_organization", %{"organization_id" => "org-unconfigured"})
    assert has_element?(view, "#api-account-#{first.id}")
    refute render(view) =~ @secret
  end

  test "OpenAI partial access failure preserves spending with a safe Admin key message",
       %{conn: conn, credential: credential} do
    HTTP.Test.stub(OpenAI, fn request ->
      if request.url.path == "/v1/organization/costs" do
        openai_response(request)
      else
        HTTP.Test.response(403, @secret)
      end
    end)

    account = create_openai_account(credential, "org-primary")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil and not &1.refreshing))
    {:ok, _view, html} = live(conn, @path)
    assert html =~ "1.25 USD"
    assert html =~ "Admin API key and Usage read permission"
    assert html =~ "Successfully fetched fields are still shown"
    assert html =~ "Unavailable — public API balance support pending."
    refute html =~ "Refresh failed"
    refute html =~ @secret
  end

  test "OpenAI rejected authorization leaves balance pending and explains Admin key requirements",
       %{conn: conn, credential: credential} do
    HTTP.Test.stub(OpenAI, fn _request -> HTTP.Test.response(401, @secret) end)
    account = create_openai_account(credential, "org-primary")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.error != nil and not &1.refreshing))
    {:ok, _view, html} = live(conn, @path)
    assert html =~ "Refresh failed"
    assert html =~ "Admin API key and Usage read permission"
    assert html =~ "Unavailable — public API balance support pending."
    assert html =~ "No successful snapshot yet"
    refute html =~ "0 USD"
    refute html =~ @secret
  end

  test "global fetching changes disable controls and retain cached successes, including paused accounts",
       %{conn: conn, credential: credential} do
    account = create_account(credential, "openrouter")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil and not &1.refreshing))
    {:ok, view, _html} = live(conn, @path)

    :ok = ApiAccounts.set_fetching_enabled(false)
    send(view.pid, :reload_states)
    html = render(view)
    assert has_element?(view, "#api-fetching-status", "Disabled")
    assert has_element?(view, "#refresh-all-api-accounts[disabled]")
    assert has_element?(view, "#refresh-api-account-#{account.id}[disabled]")
    assert html =~ "Cached data"
    assert html =~ "0 USD"
    assert html =~ "Last success"

    {:ok, _account} = ApiAccounts.update_account(account, %{active: false})
    send(view.pid, :reload_states)
    html = render(view)
    assert html =~ "Paused"
    assert html =~ "0 USD"
    refute html =~ @secret

    :ok = ApiAccounts.set_fetching_enabled(true)
    send(view.pid, :reload_states)
    assert has_element?(view, "#api-fetching-status", "Enabled")
    refute has_element?(view, "#refresh-all-api-accounts[disabled]")
    assert has_element?(view, "#refresh-api-account-#{account.id}[disabled]")
  end

  test "Settings notifications update the global indicator immediately", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      Backplane.Settings.topic(),
      {:setting_changed, "monitor.api_usage.enabled", false}
    )

    assert has_element?(view, "#api-fetching-status", "Disabled")
    assert has_element?(view, "#refresh-all-api-accounts[disabled]")

    Phoenix.PubSub.broadcast(
      Backplane.PubSub,
      Backplane.Settings.topic(),
      {:setting_changed, "monitor.api_usage.enabled", true}
    )

    assert has_element?(view, "#api-fetching-status", "Enabled")
    refute has_element?(view, "#refresh-all-api-accounts[disabled]")
  end

  test "disabled initial dashboard visits and forged refresh events never fetch providers",
       %{conn: conn, credential: credential} do
    :ok = ApiAccounts.set_fetching_enabled(false)
    owner = self()

    HTTP.Test.stub(OpenRouter, fn _request ->
      send(owner, :unexpected_provider_fetch)
      HTTP.Test.json(%{"data" => %{"usage" => 0}})
    end)

    account = create_account(credential, "openrouter")
    {:ok, view, html} = live(conn, @path)
    assert has_element?(view, "#api-fetching-status", "Disabled")
    assert has_element?(view, "#refresh-all-api-accounts[disabled]")
    assert has_element?(view, "#refresh-api-account-#{account.id}[disabled]")
    assert html =~ "No successful snapshot yet"
    refute html =~ "0 USD"
    render_click(view, "refresh", %{"id" => account.id})
    render_click(view, "refresh_all")
    refute_receive :unexpected_provider_fetch
    refute render(view) =~ @secret
  end

  test "OpenRouter management credits are account-scoped",
       %{conn: conn, credential: credential, management: management} do
    put_credential(management, "service", %{}, "management-secret-never-render")

    HTTP.Test.stub(OpenRouter, fn request ->
      case request.url.path do
        "/api/v1/key" ->
          HTTP.Test.json(%{
            "data" => %{
              "usage" => 1,
              "limit" => 5,
              "limit_remaining" => 4,
              "limit_reset" => "monthly"
            }
          })

        "/api/v1/credits" ->
          HTTP.Test.json(%{"data" => %{"total_credits" => 10, "total_usage" => 3}})
      end
    end)

    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique("managed"),
        provider: "openrouter",
        credential_name: credential,
        management_credential_name: management,
        active: true
      })

    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil))
    {:ok, _view, html} = live(conn, @path)
    assert html =~ "Key usage (all time)"
    assert html =~ "Account usage (all time)"
    assert html =~ "Purchased credits"
    assert html =~ "7 USD"
    assert html =~ "10 USD"
    assert html =~ "Remaining"
    assert html =~ "monthly"
    refute html =~ "management-secret-never-render"
  end

  test "partial management-key failure warns without hiding key spending",
       %{conn: conn, credential: credential, management: management} do
    put_credential(management, "service", %{}, "management-secret-never-render")

    HTTP.Test.stub(OpenRouter, fn request ->
      if request.url.path == "/api/v1/key" do
        HTTP.Test.json(%{"data" => %{"usage" => 2.5}})
      else
        HTTP.Test.response(403, "management-secret-never-render")
      end
    end)

    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique("partial"),
        provider: "openrouter",
        credential_name: credential,
        management_credential_name: management,
        active: true
      })

    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil))
    {:ok, _view, html} = live(conn, @path)
    assert html =~ "2.5 USD"
    assert html =~ "OpenRouter account credits unavailable"
    refute html =~ "Refresh failed"
    refute html =~ "management-secret-never-render"
  end

  test "DeepSeek preserves currency decimals, availability and absent spending",
       %{conn: conn, credential: credential} do
    HTTP.Test.stub(DeepSeek, fn _request ->
      HTTP.Test.json(%{
        "is_available" => false,
        "balance_infos" => [
          %{
            "currency" => "USD",
            "total_balance" => "0.00",
            "granted_balance" => "0.00",
            "topped_up_balance" => "0.00"
          },
          %{
            "currency" => "CNY",
            "total_balance" => "12.3456",
            "granted_balance" => "2.00",
            "topped_up_balance" => "10.3456"
          }
        ]
      })
    end)

    account = create_account(credential, "deepseek")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil))
    {:ok, view, html} = live(conn, @path)
    assert html =~ "0.00 USD"
    assert html =~ "12.3456 CNY"
    assert html =~ "Unavailable for API requests"
    assert html =~ "DeepSeek does not provide spending totals"
    assert html =~ "Granted"
    assert html =~ "Topped up"
    assert has_element?(view, "#api-account-#{account.id} local-time")
    refute html =~ @secret
  end

  test "OpenRouter key scope, missing credits and retained stale success are explicit",
       %{conn: conn, credential: credential} do
    account = create_account(credential, "openrouter")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil))
    {:ok, view, html} = live(conn, @path)
    assert html =~ "API key spending"
    assert html =~ "0 USD"
    assert html =~ "Management credential"
    assert html =~ "Unavailable"
    refute html =~ @secret

    HTTP.Test.stub(OpenRouter, fn _request ->
      HTTP.Test.json(%{"error" => @secret}, 401)
    end)

    view |> element("#refresh-api-account-#{account.id}") |> render_click()
    await_state(account.id, &(&1.error != nil and not &1.refreshing))
    send(view.pid, :reload_states)
    html = render(view)
    assert html =~ "Refresh failed"
    assert html =~ "Retained data from last successful refresh"
    assert html =~ "Last success"
    assert html =~ "Last attempt"
    assert html =~ "0 USD"
    refute html =~ @secret
  end

  test "provider-echoed reset secrets never reach cached usage or rendered errors",
       %{conn: conn, credential: credential} do
    account = create_account(credential, "openrouter")
    :ok = ApiAccounts.refresh_account(account.id)
    await_state(account.id, &(&1.last_success_at != nil))
    {:ok, view, _html} = live(conn, @path)

    HTTP.Test.stub(OpenRouter, fn _request ->
      HTTP.Test.json(%{
        "data" => %{"label" => @secret, "usage" => 2.5, "limit" => 10, "limit_reset" => @secret}
      })
    end)

    view |> element("#refresh-api-account-#{account.id}") |> render_click()
    state = await_state(account.id, &(&1.error != nil and not &1.refreshing))
    assert state.error == :invalid_response
    refute inspect(state) =~ @secret

    send(view.pid, :reload_states)
    html = render(view)
    assert html =~ "Refresh failed"
    assert html =~ "Retained data from last successful refresh"
    assert html =~ "0 USD"
    refute html =~ @secret
  end

  test "manual refresh remains responsive while pending and cached reload shows completion",
       %{conn: conn, credential: credential} do
    owner = self()

    HTTP.Test.stub(DeepSeek, fn _request ->
      send(owner, {:fetch_started, self()})

      receive do
        :complete -> HTTP.Test.json(%{"is_available" => true, "balance_infos" => []})
      after
        3_000 -> HTTP.Test.json(%{"is_available" => true, "balance_infos" => []})
      end
    end)

    account = create_account(credential, "deepseek")
    {:ok, view, _} = live(conn, @path)
    view |> element("#refresh-all-api-accounts") |> render_click()
    assert_receive {:fetch_started, task}, 1_000
    send(view.pid, :reload_states)
    assert render(view) =~ "Refreshing"
    assert_reload_interval(view, 5_000)
    assert has_element?(view, "#refresh-api-account-#{account.id}[disabled]")
    send(task, :complete)
    await_state(account.id, &(&1.last_success_at != nil and not &1.refreshing))
    send(view.pid, :reload_states)
    assert render(view) =~ "Available for API requests"
    assert_reload_interval(view, 30_000)
    refute has_element?(view, "#refresh-api-account-#{account.id}[disabled]")
  end

  defp assert_reload_interval(view, interval) do
    timer = :sys.get_state(view.pid).socket.assigns.reload_timer
    remaining = Process.read_timer(timer)
    assert is_integer(remaining)
    assert remaining > interval - 1_000
    assert remaining <= interval
  end

  defp create_account(credential, provider) do
    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique(provider),
        provider: provider,
        credential_name: credential,
        active: true
      })

    account
  end

  defp create_openai_account(credential, organization, active \\ true) do
    {:ok, account} =
      ApiAccounts.create_account(%{
        name: unique("openai"),
        provider: "openai",
        credential_name: credential,
        organization_id: organization,
        active: active
      })

    account
  end

  defp openai_response(request) do
    now = DateTime.utc_now()

    start_time =
      now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    result =
      case request.url.path do
        "/v1/organization/costs" ->
          %{"amount" => %{"value" => 1.25, "currency" => "usd"}}

        "/v1/organization/usage/completions" ->
          %{
            "input_tokens" => 100,
            "output_tokens" => 20,
            "input_cached_tokens" => 10,
            "num_model_requests" => 3
          }
      end

    HTTP.Test.json(%{
      "data" => [
        %{
          "object" => "bucket",
          "start_time" => start_time,
          "end_time" => DateTime.to_unix(now),
          "results" => [result]
        }
      ],
      "has_more" => false,
      "next_page" => nil
    })
  end

  defp put_credential(name, kind, metadata \\ %{}, secret \\ @secret) do
    Vault.put(%Credential{
      name: name,
      kind: kind,
      metadata: metadata,
      encrypted_value: Encryption.encrypt(secret)
    })
  end

  defp await_state(id, predicate, attempts \\ 100)
  defp await_state(_id, _predicate, 0), do: flunk("API usage refresh did not complete")

  defp await_state(id, predicate, attempts) do
    state = Enum.find(ApiAccounts.list_states(), &(&1.account.id == id))

    if state && predicate.(state) do
      state
    else
      Process.sleep(20)
      await_state(id, predicate, attempts - 1)
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
