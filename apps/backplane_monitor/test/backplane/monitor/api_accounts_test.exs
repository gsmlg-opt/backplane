defmodule Backplane.Monitor.ApiAccountsTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.{ApiAccount, ApiAccounts, ApiUsageServer}
  alias Backplane.Settings.{Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    name = "api-usage-key-#{System.unique_integer([:positive])}"

    Vault.put(%Credential{
      name: name,
      kind: "llm",
      encrypted_value: Encryption.encrypt("never-render-this-key")
    })

    on_exit(fn ->
      ApiUsageServer.sync([])
      Vault.remove(name)
    end)

    %{credential: name}
  end

  test "creates, changes, pauses, and deletes an API account", %{credential: credential} do
    assert {:ok, account} = ApiAccounts.create_account(attrs(credential))
    assert ApiAccounts.get_account(account.id) == account
    assert account in ApiAccounts.list_accounts()

    assert {:ok, paused} = ApiAccounts.update_account(account, %{active: false})

    assert [%{account: ^paused, refreshing: false}] =
             Enum.filter(ApiAccounts.list_states(), &(&1.account.id == account.id))

    assert {:ok, _} = ApiAccounts.delete_account(paused)
    assert ApiAccounts.get_account(account.id) == nil
    refute Enum.any?(ApiAccounts.list_states(), &(&1.account.id == account.id))
  end

  test "validates credential existence and API-key eligibility", %{credential: credential} do
    assert {:error, changeset} = ApiAccounts.create_account(attrs("missing-credential"))
    assert changeset.errors[:credential_name]

    Vault.put(%{Vault.get(credential) | metadata: %{"auth_type" => "openai_oauth"}})
    assert {:error, changeset} = ApiAccounts.create_account(attrs(credential))
    assert changeset.errors[:credential_name]
    refute Enum.any?(ApiAccounts.credential_options(), &(&1.name == credential))
  end

  test "rejects credential kinds outside account monitoring", %{credential: credential} do
    Vault.put(%{Vault.get(credential) | kind: "admin"})
    assert {:error, changeset} = ApiAccounts.create_account(attrs(credential))
    assert changeset.errors[:credential_name]
  end

  test "validates optional management references without exposing values", %{
    credential: credential
  } do
    attributes = Map.put(attrs(credential), :management_credential_name, "missing-manager")
    assert {:error, changeset} = ApiAccounts.create_account(attributes)
    assert changeset.errors[:management_credential_name]

    changeset = ApiAccounts.change_account(%ApiAccount{}, attrs(credential))
    assert changeset.valid?
    options = ApiAccounts.credential_options()
    assert Enum.any?(options, &(&1.name == credential))
    refute inspect(options) =~ "never-render-this-key"
    refute Enum.any?(options, &Map.has_key?(&1, :encrypted_value))
  end

  test "enforces unique account names", %{credential: credential} do
    attributes = attrs(credential)
    assert {:ok, _} = ApiAccounts.create_account(attributes)
    assert {:error, changeset} = ApiAccounts.create_account(attributes)
    assert changeset.errors[:name]
    ApiAccounts.list_states()
  end

  test "committed CRUD does not wait for a busy cache owner", %{credential: credential} do
    server = Process.whereis(ApiUsageServer)
    :sys.suspend(server)

    try do
      attributes = attrs(credential)
      assert {:ok, account} = ApiAccounts.create_account(attributes)
      assert {:ok, paused} = ApiAccounts.update_account(account, %{active: false})
      assert {:ok, _} = ApiAccounts.delete_account(paused)
      assert ApiAccounts.get_account(account.id) == nil
    after
      :sys.resume(server)
    end

    ApiAccounts.list_states()
  end

  test "an account can be paused after its vault credential is removed", %{credential: credential} do
    {:ok, account} = ApiAccounts.create_account(attrs(credential))
    ApiAccounts.list_states()
    active = account |> Ecto.Changeset.change(active: true) |> Backplane.Repo.update!()
    Vault.remove(credential)

    assert {:ok, paused} = ApiAccounts.update_account(active, %{active: false})
    refute paused.active
    assert [%{account: ^paused, refreshing: false}] = ApiAccounts.list_states()
  end

  test "fetching policy persists independently of account activation", %{credential: credential} do
    key = "monitor.api_usage.enabled"
    previous = Backplane.Settings.get(key)
    Backplane.Settings.subscribe()

    on_exit(fn ->
      :ets.insert(:backplane_settings, {key, previous})
      ApiUsageServer.reload_fetching_policy()
      ApiUsageServer.sync([])
    end)

    assert ApiAccounts.fetching_enabled?()
    assert :ok = ApiAccounts.set_fetching_enabled(false)
    refute ApiAccounts.fetching_enabled?()
    assert_receive {:setting_changed, ^key, false}

    assert %{value: %{"v" => false}, value_type: "boolean"} =
             Backplane.Repo.get!(Backplane.Settings.Setting, key)

    assert {:ok, account} =
             ApiAccounts.create_account(Map.put(attrs(credential), :active, true))

    assert [%{account: ^account, refreshing: false, usage: nil}] = ApiAccounts.list_states()
    assert :ok = ApiAccounts.refresh_all()
    assert [%{refreshing: false, usage: nil}] = ApiUsageServer.states()
    assert {:ok, _paused} = ApiAccounts.update_account(account, %{active: false})
    ApiAccounts.list_states()
    assert :ok = ApiAccounts.set_fetching_enabled(true)
    assert ApiAccounts.fetching_enabled?()
    assert %{value: %{"v" => true}} = Backplane.Repo.get!(Backplane.Settings.Setting, key)
    assert [%{account: %{active: false}, refreshing: false}] = ApiAccounts.list_states()
  end

  defp attrs(credential) do
    %{
      name: "Account #{System.unique_integer([:positive])}",
      provider: "openrouter",
      credential_name: credential,
      active: false
    }
  end
end
