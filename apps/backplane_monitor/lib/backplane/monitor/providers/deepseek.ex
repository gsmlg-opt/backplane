defmodule Backplane.Monitor.Providers.DeepSeek do
  @moduledoc "Fetches DeepSeek balances by currency; the balance API supplies no usage totals."

  alias Backplane.Monitor.ApiUsageFetcher

  @url "https://api.deepseek.com/user/balance"

  @spec fetch(String.t()) :: {:ok, ApiUsageFetcher.data()} | {:error, ApiUsageFetcher.reason()}
  def fetch(key) do
    with {:ok, body} <- ApiUsageFetcher.request(:deepseek_req_options, @url, key) do
      parse(body)
    end
  end

  defp parse(%{"is_available" => available, "balance_infos" => infos})
       when is_boolean(available) and is_list(infos) do
    with {:ok, balances} <- parse_balances(infos) do
      {:ok, %{balances: balances, usage: [], limit: nil, is_available: available, warnings: []}}
    end
  end

  defp parse(_body), do: {:error, :invalid_response}

  defp parse_balances(infos) do
    Enum.reduce_while(infos, {:ok, []}, fn info, {:ok, balances} ->
      case parse_balance(info) do
        {:ok, balance} -> {:cont, {:ok, balances ++ [balance]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_balance(%{"currency" => currency, "total_balance" => total} = info)
       when currency in ["USD", "CNY"] and is_binary(total) do
    with {:ok, total} <- ApiUsageFetcher.amount(total, :string),
         {:ok, granted} <- ApiUsageFetcher.amount(info["granted_balance"], :string),
         {:ok, topped_up} <- ApiUsageFetcher.amount(info["topped_up_balance"], :string) do
      {:ok,
       %{
         currency: currency,
         total_balance: total,
         granted_balance: granted,
         topped_up_balance: topped_up
       }}
    end
  end

  defp parse_balance(_info), do: {:error, :invalid_response}
end
