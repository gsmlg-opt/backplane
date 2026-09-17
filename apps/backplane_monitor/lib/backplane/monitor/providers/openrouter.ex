defmodule Backplane.Monitor.Providers.OpenRouter do
  @moduledoc "Fetches OpenRouter key spending and optional management-key account credits."

  alias Backplane.Monitor.ApiUsageFetcher

  @key_url "https://openrouter.ai/api/v1/key"
  @credits_url "https://openrouter.ai/api/v1/credits"
  @usage_fields [
    {"usage", "Key usage (all time)"},
    {"usage_daily", "Key usage (daily)"},
    {"usage_weekly", "Key usage (weekly)"},
    {"usage_monthly", "Key usage (monthly)"}
  ]

  @spec fetch(
          String.t(),
          String.t() | nil | {:ok, String.t()} | {:error, ApiUsageFetcher.reason()}
        ) ::
          {:ok, ApiUsageFetcher.data()} | {:error, ApiUsageFetcher.reason()}
  def fetch(key, management_key \\ nil) do
    with {:ok, body} <- request(@key_url, key),
         {:ok, data} <- parse_key(body) do
      {:ok, add_credits(data, management_key)}
    end
  end

  defp request(url, key),
    do: ApiUsageFetcher.request(:openrouter_req_options, url, key)

  defp parse_key(%{"data" => key_data}) when is_map(key_data) do
    with {:ok, usage} <- parse_usage(key_data),
         {:ok, limit} <- parse_limit(key_data) do
      {:ok, %{balances: [], usage: usage, limit: limit, is_available: nil, warnings: []}}
    end
  end

  defp parse_key(_body), do: {:error, :invalid_response}

  defp parse_usage(key_data) do
    Enum.reduce_while(@usage_fields, {:ok, []}, fn {field, label}, {:ok, usage} ->
      case ApiUsageFetcher.amount(key_data[field], :number) do
        {:ok, nil} ->
          {:cont, {:ok, usage}}

        {:ok, amount} ->
          {:cont, {:ok, usage ++ [%{label: label, amount: amount, currency: "USD"}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_limit(key_data) do
    reset = key_data["limit_reset"]

    with {:ok, amount} <- ApiUsageFetcher.amount(key_data["limit"], :number),
         {:ok, remaining} <- ApiUsageFetcher.amount(key_data["limit_remaining"], :number),
         true <- reset in [nil, "daily", "weekly", "monthly"] do
      if is_nil(amount) and is_nil(remaining) and is_nil(reset) do
        {:ok, nil}
      else
        {:ok, %{amount: amount, remaining: remaining, currency: "USD", reset: reset}}
      end
    else
      _other -> {:error, :invalid_response}
    end
  end

  defp add_credits(data, nil), do: data
  defp add_credits(data, {:ok, key}), do: add_credits(data, key)
  defp add_credits(data, {:error, reason}), do: %{data | warnings: [{:account_credits, reason}]}

  defp add_credits(data, key) when is_binary(key) do
    with {:ok, body} <- request(@credits_url, key),
         {:ok, credits, usage} <- parse_credits(body) do
      remaining = remaining_balance(credits, usage)

      %{
        data
        | balances: [
            %{
              currency: "USD",
              total_balance: remaining,
              granted_balance: nil,
              topped_up_balance: credits
            }
          ],
          usage:
            data.usage ++ [%{label: "Account usage (all time)", amount: usage, currency: "USD"}]
      }
    else
      {:error, reason} -> %{data | warnings: [{:account_credits, reason}]}
    end
  rescue
    _exception -> %{data | warnings: [{:account_credits, :invalid_response}]}
  end

  defp remaining_balance(credits, usage) do
    context = %Decimal.Context{
      precision: byte_size(credits) + byte_size(usage) + 1,
      traps: [:invalid_operation, :division_by_zero, :overflow, :underflow, :inexact, :rounded]
    }

    Decimal.Context.with(context, fn ->
      credits
      |> Decimal.new(max_digits: byte_size(credits))
      |> Decimal.sub(Decimal.new(usage, max_digits: byte_size(usage)))
      |> Decimal.to_string(:normal)
    end)
  end

  defp parse_credits(%{"data" => %{"total_credits" => credits, "total_usage" => usage}})
       when not is_nil(credits) and not is_nil(usage) do
    with {:ok, credits} <- ApiUsageFetcher.amount(credits, :number),
         {:ok, usage} <- ApiUsageFetcher.amount(usage, :number) do
      {:ok, credits, usage}
    end
  end

  defp parse_credits(_body), do: {:error, :invalid_response}
end
