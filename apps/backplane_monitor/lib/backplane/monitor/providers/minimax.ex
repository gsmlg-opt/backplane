defmodule Backplane.Monitor.Providers.MiniMax do
  @moduledoc """
  Fetches usage data from the MiniMax coding plan API.

  Endpoint: `GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`
  Auth: Bearer token

  Response shape:
  ```json
  {
    "model_remains": [
      {
        "start_time": 1780434000000,
        "end_time": 1780452000000,
        "remains_time": 60284,
        "current_interval_total_count": 0,
        "current_interval_usage_count": 0,
        "model_name": "general",
        "current_weekly_total_count": 0,
        "current_weekly_usage_count": 0,
        "weekly_start_time": 1780243200000,
        "weekly_end_time": 1780848000000,
        "weekly_remains_time": 396060284,
        "current_interval_status": 1,
        "current_interval_remaining_percent": 97,
        "current_weekly_status": 1,
        "current_weekly_remaining_percent": 96,
        "interval_boost_permille": 2000,
        "weekly_boost_permille": 3000
      }
    ],
    "base_resp": {
      "status_code": 0,
      "status_msg": "success"
    }
  }
  ```
  """

  @default_url "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

  @doc "Fetch MiniMax coding plan usage data."
  @spec fetch(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch(api_key, config \\ %{}) do
    url = config["api_url"] || @default_url
    req_options = Application.get_env(:backplane, :minimax_monitor_req_options, [])

    case Req.get(
           url,
           [headers: [{"authorization", "Bearer #{api_key}"}], receive_timeout: 15_000] ++
             req_options
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp parse_response(%{"model_remains" => models}) when is_list(models) do
    %{
      provider: "minimax",
      models: Enum.map(models, &parse_model/1)
    }
  end

  defp parse_response(body) do
    %{provider: "minimax", models: [], raw: body}
  end

  defp parse_model(model) do
    interval_boost = model["interval_boost_permille"] || 1000
    weekly_boost = model["weekly_boost_permille"] || 1000

    interval_total = model["current_interval_total_count"] || 0
    interval_remaining_raw = model["current_interval_usage_count"] || 0

    interval_remaining_pct_raw =
      model["current_interval_remaining_percent"] ||
        if interval_total > 0, do: round(interval_remaining_raw / interval_total * 100), else: 100

    interval_used_pct = round((100 - interval_remaining_pct_raw) * (interval_boost / 1000))
    current_interval_remaining_percent = max(100 - interval_used_pct, 0)

    {total, remaining} =
      if interval_total > 0 do
        {interval_total, interval_remaining_raw}
      else
        {100, current_interval_remaining_percent}
      end

    used = total - remaining

    weekly_total_raw = model["current_weekly_total_count"] || model["weekly_total_count"] || 0
    weekly_remaining_raw = model["current_weekly_usage_count"] || model["weekly_usage_count"] || 0

    weekly_remaining_pct_raw =
      model["current_weekly_remaining_percent"] ||
        if weekly_total_raw > 0,
          do: round(weekly_remaining_raw / weekly_total_raw * 100),
          else: 100

    weekly_used_pct = round((100 - weekly_remaining_pct_raw) * (weekly_boost / 1000))
    current_weekly_remaining_percent = max(100 - weekly_used_pct, 0)

    {weekly_total, weekly_remaining} =
      if weekly_total_raw > 0 do
        {weekly_total_raw, weekly_remaining_raw}
      else
        {100, current_weekly_remaining_percent}
      end

    weekly_used = weekly_total - weekly_remaining

    next_reset = model["end_time"] || model["next_reset_time"]

    %{
      name: model["model_name"],
      used: used,
      total: total,
      remaining: remaining,
      next_reset: parse_timestamp(next_reset),
      weekly_used: weekly_used,
      weekly_total: weekly_total,
      weekly_remaining: weekly_remaining,
      current_interval_remaining_percent: current_interval_remaining_percent,
      current_weekly_remaining_percent: current_weekly_remaining_percent,
      start_time: parse_timestamp(model["start_time"]),
      end_time: parse_timestamp(model["end_time"]),
      remains_time: model["remains_time"],
      weekly_start_time: parse_timestamp(model["weekly_start_time"]),
      weekly_end_time: parse_timestamp(model["weekly_end_time"]),
      weekly_remains_time: model["weekly_remains_time"]
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ms) when is_integer(ms) do
    DateTime.from_unix!(div(ms, 1000))
  end
end
