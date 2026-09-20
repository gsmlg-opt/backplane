defmodule Backplane.Monitor.Providers.Firecrawl do
  @moduledoc "Fetches Firecrawl team credit usage."

  alias Backplane.Monitor.ApiUsageFetcher

  @url "https://api.firecrawl.dev/v2/team/credit-usage"

  @spec fetch(String.t()) :: {:ok, ApiUsageFetcher.data()} | {:error, ApiUsageFetcher.reason()}
  def fetch(key) do
    with {:ok, body} <- ApiUsageFetcher.request(:firecrawl_req_options, @url, key),
         {:ok, data} <- parse(body) do
      {:ok, data}
    end
  end

  defp parse(%{"success" => true, "data" => data}) when is_map(data) do
    with {:ok, remaining} <- ApiUsageFetcher.amount(data["remainingCredits"], :number),
         {:ok, plan} <- ApiUsageFetcher.amount(data["planCredits"], :number) do
      {:ok,
       %{
         balances: [],
         usage: [],
         limit: %{
           amount: plan,
           remaining: remaining,
           currency: "credits",
           reset: data["billingPeriodEnd"]
         },
         is_available: true,
         warnings: []
       }}
    end
  end

  defp parse(_body), do: {:error, :invalid_response}
end
