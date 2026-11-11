defmodule Backplane.Monitor.ApiUsageFetcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.{ApiAccount, ApiUsageFetcher, ApiUsageServer}
  alias Backplane.Monitor.Providers.{DeepSeek, OpenAI, OpenRouter}
  alias Backplane.Settings.{Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault

  setup_all do
    if :ets.whereis(:credentials_vault) == :undefined do
      :ets.new(:credentials_vault, [:named_table, :set, :public])
    end

    :ok
  end

  setup do
    HTTP.Test.verify_on_exit!()

    for {option, provider} <- [
          openrouter_http_options: OpenRouter,
          deepseek_http_options: DeepSeek,
          openai_http_options: OpenAI
        ] do
      previous = Application.get_env(:backplane_monitor, option)
      Application.put_env(:backplane_monitor, option, adapter: {HTTP.Test, provider})

      on_exit(fn ->
        if previous do
          Application.put_env(:backplane_monitor, option, previous)
        else
          Application.delete_env(:backplane_monitor, option)
        end
      end)
    end

    :ok
  end

  test "dispatches eligible vaulted API keys to each provider without plaintext in results" do
    for {provider, module, body} <- [
          {"openrouter", OpenRouter, %{data: %{usage: 1}}},
          {"deepseek", DeepSeek, %{is_available: true, balance_infos: []}}
        ],
        kind <- ["llm", "service", "admin"],
        auth_type <- [nil, "api_key"] do
      name = credential(kind, auth_type, "private-key")

      HTTP.Test.stub(module, fn request ->
        assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer private-key"]
        HTTP.Test.json(body)
      end)

      assert {:ok, result} = ApiUsageFetcher.fetch_usage(account(provider, name))
      refute inspect(result) =~ "private-key"
    end
  end

  test "rejects missing credentials, invalid kinds and OAuth before any request" do
    assert {:error, :credential_not_found} =
             ApiUsageFetcher.fetch_usage(account("deepseek", "missing"))

    assert {:error, :credential_not_found} = ApiUsageFetcher.fetch_usage(account("deepseek", nil))

    for kind <- ["script", "upstream", "custom"] do
      name = credential(kind, nil, "private-key")

      assert {:error, :invalid_credential_kind} =
               ApiUsageFetcher.fetch_usage(account("deepseek", name))
    end

    for auth_type <- ["openai_oauth", "oauth2_client_credentials", "private-key"] do
      name = credential("llm", auth_type, "private-key")

      assert {:error, :invalid_credential_auth_type} =
               ApiUsageFetcher.fetch_usage(account("openrouter", name))
    end
  end

  test "rejects invalid encrypted and empty or unsafe decrypted keys without leaking values" do
    name = credential("llm", nil, "private-key")
    Vault.put(%{Vault.get(name) | encrypted_value: "private-key"})
    assert {:error, :decryption_failed} = ApiUsageFetcher.fetch_usage(account("openrouter", name))

    for key <- ["", "  ", "private-key\r\nunsafe", "private key"] do
      name = credential("service", nil, key)

      assert {:error, :invalid_credential} =
               ApiUsageFetcher.fetch_usage(account("openrouter", name))
    end
  end

  test "optional missing or ineligible management credentials preserve successful key usage" do
    HTTP.Test.stub(OpenRouter, fn request ->
      assert request.url.path == "/api/v1/key"
      HTTP.Test.json(%{data: %{usage: 1}})
    end)

    name = credential("llm", nil, "private-key")

    for management <- [
          "missing",
          credential("script", nil, "management-secret"),
          credential("llm", "openai_oauth", "management-secret")
        ] do
      assert {:ok, result} = ApiUsageFetcher.fetch_usage(account("openrouter", name, management))
      assert [{:account_credits, _reason}] = result.warnings
      assert result.usage == [%{label: "Key usage (all time)", amount: "1", currency: "USD"}]
      refute inspect(result) =~ "management-secret"
    end
  end

  test "resolves optional management key independently and ignores it for DeepSeek" do
    name = credential("llm", nil, "private-key")
    management = credential("service", "api_key", "management-secret")

    HTTP.Test.stub(OpenRouter, fn request ->
      if request.url.path == "/api/v1/key" do
        assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer private-key"]
        HTTP.Test.json(%{data: %{usage: 1}})
      else
        assert HTTP.Headers.get_all(request.headers, "authorization") == [
                 "Bearer management-secret"
               ]

        HTTP.Test.json(%{data: %{total_credits: 10, total_usage: 1}})
      end
    end)

    assert {:ok, %{balances: [%{total_balance: "9"}], warnings: []}} =
             ApiUsageFetcher.fetch_usage(account("openrouter", name, management))

    HTTP.Test.stub(DeepSeek, fn _request ->
      HTTP.Test.json(%{is_available: true, balance_infos: []})
    end)

    assert {:ok, %{warnings: []}} =
             ApiUsageFetcher.fetch_usage(account("deepseek", name, "missing"))
  end

  test "unsupported providers fail without resolving credentials" do
    assert {:error, :provider_not_supported} =
             ApiUsageFetcher.fetch_usage(account("unknown", "missing"))
  end

  test "dispatches OpenAI Admin keys with an explicit organization and rejects OAuth" do
    name = credential("service", "api_key", "private-admin-key")

    HTTP.Test.stub(OpenAI, fn request ->
      assert HTTP.Headers.get_all(request.headers, "authorization") == [
               "Bearer private-admin-key"
             ]

      assert HTTP.Headers.get_all(request.headers, "openai-organization") == ["org-selected"]
      assert request.url.path in ["/v1/organization/costs", "/v1/organization/usage/completions"]
      HTTP.Test.json(%{data: [], has_more: false, next_page: nil})
    end)

    definition = struct!(account("openai", name), organization_id: "org-selected")

    assert {:ok, %{metrics: metrics, balances: []} = result} =
             ApiUsageFetcher.fetch_usage(definition)

    assert length(metrics) == 8
    refute inspect(result) =~ "private-admin-key"

    oauth = credential("llm", "openai_oauth", "private-oauth-token")

    assert {:error, :invalid_credential_auth_type} =
             ApiUsageFetcher.fetch_usage(%{definition | credential_name: oauth})
  end

  test "provider mock ownership can be explicitly allowed to a polling task" do
    name = credential("service", nil, "private-key")
    HTTP.Test.stub(OpenRouter, fn _request -> HTTP.Test.json(%{data: %{usage: 1}}) end)

    # spawn/1 has no $callers chain, so the explicit allowance is what grants access.
    task =
      spawn_task(fn ->
        receive do
          :fetch -> ApiUsageFetcher.fetch_usage(account("openrouter", name))
        end
      end)

    HTTP.Test.allow(OpenRouter, self(), task)
    send(task, :fetch)
    assert_receive {:fetched, {:ok, %{warnings: []}}}
  end

  test "ApiUsageServer polling tasks reach the configured :http_test_owner stubs" do
    name = credential("service", nil, "private-key")
    HTTP.Test.stub(OpenRouter, fn _request -> HTTP.Test.json(%{data: %{usage: 1}}) end)

    previous = Application.get_env(:backplane_monitor, :http_test_owner)
    Application.put_env(:backplane_monitor, :http_test_owner, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:backplane_monitor, :http_test_owner, previous),
        else: Application.delete_env(:backplane_monitor, :http_test_owner)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    server =
      start_supervised!(
        {ApiUsageServer,
         name: nil,
         task_supervisor: supervisor,
         enabled_reader: fn -> true end,
         refresh_interval: 0}
      )

    account = struct!(account("openrouter", name), id: Ecto.UUID.generate())
    ApiUsageServer.sync(server, [account])

    assert %{usage: %{warnings: []}, error: nil} = await_usage(server, account.id)
  end

  defp await_usage(server, id, attempts \\ 100)
  defp await_usage(_server, _id, 0), do: flunk("refresh did not finish")

  defp await_usage(server, id, attempts) do
    case Enum.find(ApiUsageServer.states(server), &(&1.account.id == id)) do
      %{refreshing: false, fetched_at: %DateTime{}} = snapshot ->
        snapshot

      _snapshot ->
        Process.sleep(10)
        await_usage(server, id, attempts - 1)
    end
  end

  defp spawn_task(fun) do
    parent = self()
    spawn(fn -> send(parent, {:fetched, fun.()}) end)
  end

  defp account(provider, name, management \\ nil) do
    struct!(ApiAccount,
      provider: provider,
      name: "test",
      credential_name: name,
      management_credential_name: management,
      active: true
    )
  end

  defp credential(kind, auth_type, key) do
    name = "api-usage-test-#{System.unique_integer([:positive])}"

    Vault.put(%Credential{
      name: name,
      kind: kind,
      metadata: %{"auth_type" => auth_type},
      encrypted_value: Encryption.encrypt(key)
    })

    on_exit(fn -> Vault.remove(name) end)
    name
  end
end
