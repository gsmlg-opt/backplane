defmodule Backplane.Monitor.UsageFetcher do
  @moduledoc """
  Dispatches usage queries to provider-specific modules.

  Decrypts the plan's credential and delegates to the appropriate provider
  module to fetch live usage data.
  """

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.Providers.{ClaudeCode, MiniMax, ZAI}
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  @doc """
  Fetch usage data for a plan.

  Returns `{:ok, usage_data}` or `{:error, reason}`.
  """
  @spec fetch_usage(Plan.t()) :: {:ok, map()} | {:error, term()}
  def fetch_usage(%Plan{provider: provider} = plan) do
    if Plan.provider_supported?(provider) do
      with {:ok, credential} <- fetch_credential(provider, plan.credential_name) do
        fetch_provider(provider, credential, plan.config)
      end
    else
      {:error, :provider_not_supported}
    end
  end

  defp fetch_credential("claude_code", credential_name) do
    with :ok <- validate_script_credential(credential_name),
         {:ok, script} <- Credentials.fetch(credential_name) do
      {:ok, script}
    end
  end

  defp fetch_credential(_provider, credential_name), do: Credentials.fetch(credential_name)

  defp validate_script_credential(credential_name) do
    case Vault.get(credential_name) do
      nil -> {:error, :not_found}
      %{kind: "script"} -> :ok
      %{kind: kind} -> {:error, {:invalid_credential_kind, kind, "script"}}
    end
  end

  defp fetch_provider("zai", api_key, config), do: ZAI.fetch(api_key, config)
  defp fetch_provider("minimax", api_key, config), do: MiniMax.fetch(api_key, config)
  defp fetch_provider("claude_code", script, config), do: ClaudeCode.fetch(script, config)
  defp fetch_provider(_, _, _), do: {:error, :provider_not_supported}
end
