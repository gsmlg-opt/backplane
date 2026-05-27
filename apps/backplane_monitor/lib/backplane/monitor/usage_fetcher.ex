defmodule Backplane.Monitor.UsageFetcher do
  @moduledoc """
  Dispatches usage queries to provider-specific modules.

  Decrypts the plan's credential and delegates to the appropriate provider
  module to fetch live usage data.
  """

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.Providers.{MiniMax, ZAI}
  alias Backplane.Settings.Credentials

  @doc """
  Fetch usage data for a plan.

  Returns `{:ok, usage_data}` or `{:error, reason}`.
  """
  @spec fetch_usage(Plan.t()) :: {:ok, map()} | {:error, term()}
  def fetch_usage(%Plan{provider: provider} = plan) do
    if Plan.provider_supported?(provider) do
      with {:ok, api_key} <- Credentials.fetch(plan.credential_name) do
        fetch_provider(provider, api_key, plan.config)
      end
    else
      {:error, :provider_not_supported}
    end
  end

  defp fetch_provider("zai", api_key, config), do: ZAI.fetch(api_key, config)
  defp fetch_provider("minimax", api_key, config), do: MiniMax.fetch(api_key, config)
  defp fetch_provider(_, _, _), do: {:error, :provider_not_supported}
end
