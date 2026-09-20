defmodule Backplane.Monitor.Providers.Tavily do
  @moduledoc "Fetches Tavily API-key and account usage."

  alias Backplane.Monitor.ApiUsageFetcher

  @url "https://api.tavily.com/usage"

  @spec fetch(String.t()) :: {:ok, ApiUsageFetcher.data()} | {:error, ApiUsageFetcher.reason()}
  def fetch(key) do
    with {:ok, body} <- ApiUsageFetcher.request(:tavily_req_options, @url, key),
         {:ok, data} <- parse(body) do
      {:ok, data}
    end
  end

  defp parse(%{"key" => key} = body) when is_map(key) do
    account = Map.get(body, "account", %{})

    with {:ok, usage} <- parse_usage(key, "Key"),
         {:ok, usage} <- append_usage(usage, account, "Account") do
      {:ok,
       %{balances: [], usage: usage, limit: parse_limit(key), is_available: true, warnings: []}}
    end
  end

  defp parse(_body), do: {:error, :invalid_response}

  defp parse_usage(data, prefix) do
    Enum.reduce_while(
      [
        {"usage", "Total"},
        {"search_usage", "Search"},
        {"extract_usage", "Extract"},
        {"crawl_usage", "Crawl"},
        {"map_usage", "Map"},
        {"research_usage", "Research"}
      ],
      {:ok, []},
      fn {field, label}, {:ok, usage} ->
        case ApiUsageFetcher.amount(data[field], :number) do
          {:ok, nil} ->
            {:cont, {:ok, usage}}

          {:ok, amount} ->
            {:cont,
             {:ok, usage ++ [%{label: "#{prefix} #{label}", amount: amount, currency: "credits"}]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp append_usage(usage, data, prefix) when is_map(data) do
    case parse_usage(data, prefix) do
      {:ok, extra} -> {:ok, usage ++ extra}
      error -> error
    end
  end

  defp parse_limit(data) do
    case ApiUsageFetcher.amount(data["limit"], :number) do
      {:ok, value} when not is_nil(value) ->
        %{amount: value, remaining: nil, currency: "credits", reset: nil}

      _ ->
        nil
    end
  end
end
