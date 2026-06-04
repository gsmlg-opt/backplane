defmodule Backplane.Monitor.UsageFetcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.UsageFetcher
  alias Backplane.Settings.Credential
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    Ecto.Adapters.SQL.Sandbox.allow(Backplane.Repo, self(), Backplane.Settings.Credentials.Vault)
    :ok
  end

  test "fetch_usage/1 runs Claude Code script credentials" do
    credential_name = unique_name("claude-script")
    usage = %{"subscription" => "max", "tokens" => %{"used" => 9, "limit" => 20}}

    {:ok, _credential} = Credentials.store(credential_name, usage_script(usage), "script")

    plan = %Plan{
      provider: "claude_code",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "claude_code"
    assert result.usage == usage
  end

  test "fetch_usage/1 rejects non-script credentials for Claude Code" do
    credential_name = unique_name("claude-key")
    Vault.put(%Credential{name: credential_name, kind: "llm", encrypted_value: <<>>})
    on_exit(fn -> Vault.remove(credential_name) end)

    plan = %Plan{provider: "claude_code", credential_name: credential_name, config: %{}}

    assert {:error, {:invalid_credential_kind, "llm", "script"}} = UsageFetcher.fetch_usage(plan)
  end

  defp usage_script(usage) do
    """
    const response = await fetch("#{data_url(usage)}");
    const data = await response.json();
    return data;
    """
  end

  defp data_url(payload) do
    "data:application/json;base64,#{payload |> Jason.encode!() |> Base.encode64()}"
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
