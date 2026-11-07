defmodule Backplane.Monitor.Providers.OpenAI do
  @moduledoc "Fetches organization costs and Completions usage using an OpenAI Admin API key."

  alias Backplane.Monitor.{ApiAccount, ApiUsageFetcher}

  @base_url "https://api.openai.com/v1/organization/"
  @max_pages 10
  @counters [
    {"input_tokens", "Input tokens", "tokens"},
    {"output_tokens", "Output tokens", "tokens"},
    {"input_cached_tokens", "Cached input tokens", "tokens"},
    {"num_model_requests", "Model requests", "requests"}
  ]

  @spec fetch(String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, ApiUsageFetcher.data()} | {:error, ApiUsageFetcher.reason()}
  def fetch(key, organization_id, now \\ DateTime.utc_now()) do
    if ApiAccount.valid_organization_id?(organization_id) do
      now = now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
      date = DateTime.to_date(now)
      today = date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

      params = [
        start_time:
          date
          |> Date.beginning_of_month()
          |> DateTime.new!(~T[00:00:00], "Etc/UTC")
          |> DateTime.to_unix(),
        end_time: DateTime.to_unix(now),
        bucket_width: "1d",
        limit: 31
      ]

      costs = fetch_data("costs", key, organization_id, params, today, &parse_costs/2)
      usage = fetch_data("usage/completions", key, organization_id, params, today, &parse_usage/2)
      combine(costs, usage)
    else
      {:error, :invalid_organization}
    end
  end

  defp fetch_data(path, key, organization, params, today, parser) do
    with {:ok, buckets} <- pages(path, key, organization, params, MapSet.new(), []) do
      parser.(buckets, today)
    end
  rescue
    _exception -> {:error, :invalid_response}
  end

  defp pages(path, key, organization, params, seen, buckets) do
    url = @base_url <> path <> "?" <> URI.encode_query(params)

    with {:ok, body} <-
           ApiUsageFetcher.request(:openai_req_options, url, key, "authorization", [
             {"openai-organization", organization}
           ]),
         %{"data" => data, "has_more" => more} when is_list(data) and is_boolean(more) <- body,
         true <- Enum.all?(data, &valid_bucket?(&1, params)) do
      buckets = [data | buckets]

      if more do
        next_page(path, key, organization, params, body["next_page"], seen, buckets)
      else
        {:ok, buckets |> Enum.reverse() |> List.flatten()}
      end
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_response}
    end
  end

  defp next_page(path, key, organization, params, cursor, seen, buckets) do
    if is_binary(cursor) and cursor != "" and not MapSet.member?(seen, cursor) and
         MapSet.size(seen) < @max_pages - 1 do
      pages(
        path,
        key,
        organization,
        Keyword.put(params, :page, cursor),
        MapSet.put(seen, cursor),
        buckets
      )
    else
      {:error, :invalid_response}
    end
  end

  defp valid_bucket?(
         %{
           "object" => "bucket",
           "start_time" => start,
           "end_time" => finish,
           "results" => results
         },
         params
       )
       when is_integer(start) and is_integer(finish) and is_list(results) do
    start >= params[:start_time] and start < params[:end_time] and finish > start and
      rem(start, 86_400) == 0 and Enum.all?(results, &is_map/1)
  end

  defp valid_bucket?(_bucket, _params), do: false

  defp parse_costs(buckets, today) do
    Enum.reduce_while(periods(buckets, today), {:ok, []}, fn {period, results}, {:ok, totals} ->
      case cost_values(results) do
        {:ok, amounts} ->
          total = %{
            label: "Organization spending (#{period}, UTC)",
            amount: sum(amounts),
            currency: "USD"
          }

          {:cont, {:ok, totals ++ [total]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp cost_values(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      %{"amount" => %{"currency" => currency, "value" => value}}, {:ok, values}
      when currency in ["usd", "USD"] and not is_nil(value) ->
        case ApiUsageFetcher.amount(value, :number) do
          {:ok, amount} ->
            {:cont, {:ok, [Decimal.new(amount, max_digits: byte_size(amount)) | values]}}

          error ->
            {:halt, error}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_response}}
    end)
  end

  defp sum([]), do: "0"

  defp sum(values) do
    integer_digits =
      Enum.max(Enum.map(values, &max(byte_size(Integer.to_string(&1.coef)) + &1.exp, 1)))

    fractional_digits = Enum.max(Enum.map(values, &max(-&1.exp, 0)))

    context = %Decimal.Context{
      precision:
        integer_digits + fractional_digits + byte_size(Integer.to_string(length(values))) + 1,
      traps: [:invalid_operation, :division_by_zero, :overflow, :underflow, :inexact, :rounded]
    }

    Decimal.Context.with(context, fn ->
      values
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)
    end)
  end

  defp parse_usage(buckets, today) do
    Enum.reduce_while(periods(buckets, today), {:ok, []}, fn {period, results}, {:ok, metrics} ->
      case counters(results, period) do
        {:ok, counters} -> {:cont, {:ok, metrics ++ counters}}
        error -> {:halt, error}
      end
    end)
  end

  defp counters(results, period) do
    Enum.reduce_while(@counters, {:ok, []}, fn {field, label, unit}, {:ok, metrics} ->
      values = Enum.map(results, &Map.get(&1, field))

      cond do
        Enum.any?(values, &(not is_nil(&1) and (not is_integer(&1) or &1 < 0))) ->
          {:halt, {:error, :invalid_response}}

        field == "input_cached_tokens" and Enum.any?(values, &is_nil/1) ->
          {:cont, {:ok, metrics}}

        Enum.any?(values, &is_nil/1) ->
          {:halt, {:error, :invalid_response}}

        true ->
          metric = %{
            label: "#{label} (#{period}, UTC)",
            amount: Integer.to_string(Enum.sum(values)),
            unit: unit
          }

          {:cont, {:ok, metrics ++ [metric]}}
      end
    end)
  end

  defp periods(buckets, today) do
    [
      {"today",
       buckets |> Enum.filter(&(&1["start_time"] >= today)) |> Enum.flat_map(& &1["results"])},
      {"month to date", Enum.flat_map(buckets, & &1["results"])}
    ]
  end

  defp combine({:error, reason}, {:error, _usage_reason}), do: {:error, reason}

  defp combine(costs, usage) do
    {spending, cost_warnings} = result(costs, :organization_costs)
    {metrics, usage_warnings} = result(usage, :organization_usage)

    # Balance polling is deferred until a public API is documented; see README.
    {:ok,
     %{
       balances: [],
       usage: spending,
       metrics: metrics,
       limit: nil,
       is_available: nil,
       warnings: [{:account_balance, :not_supported}] ++ cost_warnings ++ usage_warnings
     }}
  end

  defp result({:ok, values}, _field), do: {values, []}
  defp result({:error, reason}, field), do: {[], [{field, reason}]}
end
