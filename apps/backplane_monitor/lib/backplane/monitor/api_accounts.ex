defmodule Backplane.Monitor.ApiAccounts do
  @moduledoc "API-account definitions and their ephemeral usage snapshots."

  import Ecto.Query
  import Ecto.Changeset

  alias Backplane.Monitor.{ApiAccount, ApiUsageServer}
  alias Backplane.Repo
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  def list_accounts do
    ApiAccount |> order_by(:name) |> Repo.all()
  end

  def get_account(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(ApiAccount, uuid)
      :error -> nil
    end
  end

  def change_account(account, attrs \\ %{}) do
    changeset = ApiAccount.changeset(account, attrs)

    if account.__meta__.state == :loaded and changeset.changes == %{active: false} do
      changeset
    else
      changeset
      |> validate_credential(:credential_name)
      |> validate_credential(:management_credential_name)
    end
  end

  def create_account(attrs) do
    %ApiAccount{} |> change_account(attrs) |> Repo.insert() |> sync_result()
  end

  def update_account(%ApiAccount{} = account, attrs) do
    account |> change_account(attrs) |> Repo.update() |> sync_result()
  end

  def delete_account(%ApiAccount{} = account) do
    case Repo.delete(account) do
      {:ok, deleted} = result ->
        ApiUsageServer.definition_changed(deleted.id)
        result

      {:error, _changeset} = result ->
        result
    end
  end

  def credential_options do
    Credentials.list() |> Enum.filter(&api_key_credential?/1)
  end

  def api_key_credential?(%{kind: kind, metadata: metadata}) do
    kind in ~w(llm service) and Map.get(metadata || %{}, "auth_type") in [nil, "api_key"]
  end

  def api_key_credential?(_credential), do: false

  def list_states do
    ApiUsageServer.load_states()
  end

  def fetching_enabled?, do: Backplane.Settings.get("monitor.api_usage.enabled") == true

  def set_fetching_enabled(enabled) when is_boolean(enabled) do
    with :ok <- Backplane.Settings.set("monitor.api_usage.enabled", enabled) do
      ApiUsageServer.reload_fetching_policy()
    end
  end

  def refresh_account(id) do
    ApiUsageServer.refresh(id)
  end

  def refresh_all do
    ApiUsageServer.refresh_all()
  end

  defp validate_credential(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      name ->
        if api_key_credential?(Vault.get(name)) do
          changeset
        else
          add_error(
            changeset,
            field,
            "must reference an existing LLM or service API-key credential"
          )
        end
    end
  end

  defp sync_result({:ok, account} = result) do
    ApiUsageServer.definition_changed(account.id)
    result
  end

  defp sync_result({:error, _changeset} = result), do: result
end
