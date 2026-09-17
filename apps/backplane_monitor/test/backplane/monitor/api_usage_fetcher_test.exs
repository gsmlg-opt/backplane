defmodule Backplane.Monitor.ApiUsageFetcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.{ApiAccount, ApiUsageFetcher}
  alias Backplane.Monitor.Providers.{DeepSeek, OpenRouter}
  alias Backplane.Settings.{Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:req)

    if :ets.whereis(:credentials_vault) == :undefined do
      :ets.new(:credentials_vault, [:named_table, :set, :public])
    end

    :ok
  end

  setup do
    for {option, provider} <- [openrouter_req_options: OpenRouter, deepseek_req_options: DeepSeek] do
      previous = Application.get_env(:backplane_monitor, option)
      Application.put_env(:backplane_monitor, option, plug: {Req.Test, provider})

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
        kind <- ["llm", "service"],
        auth_type <- [nil, "api_key"] do
      name = credential(kind, auth_type, "private-key")

      Req.Test.stub(module, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private-key"]
        Req.Test.json(conn, body)
      end)

      assert {:ok, result} = ApiUsageFetcher.fetch_usage(account(provider, name))
      refute inspect(result) =~ "private-key"
    end
  end

  test "rejects missing credentials, invalid kinds and OAuth before any request" do
    assert {:error, :credential_not_found} =
             ApiUsageFetcher.fetch_usage(account("deepseek", "missing"))

    assert {:error, :credential_not_found} = ApiUsageFetcher.fetch_usage(account("deepseek", nil))

    for kind <- ["script", "admin", "upstream", "custom"] do
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
    Req.Test.stub(OpenRouter, fn conn ->
      assert conn.request_path == "/api/v1/key"
      Req.Test.json(conn, %{data: %{usage: 1}})
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

    Req.Test.stub(OpenRouter, fn conn ->
      if conn.request_path == "/api/v1/key" do
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private-key"]
        Req.Test.json(conn, %{data: %{usage: 1}})
      else
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer management-secret"]
        Req.Test.json(conn, %{data: %{total_credits: 10, total_usage: 1}})
      end
    end)

    assert {:ok, %{balances: [%{total_balance: "9"}], warnings: []}} =
             ApiUsageFetcher.fetch_usage(account("openrouter", name, management))

    Req.Test.stub(DeepSeek, &Req.Test.json(&1, %{is_available: true, balance_infos: []}))

    assert {:ok, %{warnings: []}} =
             ApiUsageFetcher.fetch_usage(account("deepseek", name, "missing"))
  end

  test "unsupported providers fail without resolving credentials" do
    assert {:error, :provider_not_supported} =
             ApiUsageFetcher.fetch_usage(account("unknown", "missing"))
  end

  test "provider mock ownership can be explicitly allowed to a polling task" do
    name = credential("service", nil, "private-key")
    Req.Test.stub(OpenRouter, &Req.Test.json(&1, %{data: %{usage: 1}}))

    task =
      Task.async(fn ->
        receive do
          :fetch -> ApiUsageFetcher.fetch_usage(account("openrouter", name))
        end
      end)

    Req.Test.allow(OpenRouter, self(), task.pid)
    send(task.pid, :fetch)
    assert {:ok, %{warnings: []}} = Task.await(task)
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
