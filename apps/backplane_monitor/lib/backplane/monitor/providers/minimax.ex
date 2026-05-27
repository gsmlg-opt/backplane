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
        "model_name": "text_generation",
        "current_interval_usage_count": 1381,
        "current_interval_total_count": 1500,
        "next_reset_time": 1748400000000,
        "weekly_usage_count": 11248,
        "weekly_total_count": 15000
      }
    ]
  }
  ```

  Note: `current_interval_usage_count` is the *remaining* count (not used).
  """

  @default_url "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains"

  @doc "Fetch MiniMax coding plan usage data."
  @spec fetch(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def fetch(api_key, config \\ %{}) do
    url = config["api_url"] || @default_url

    case Req.get(url, headers: [{"authorization", "Bearer #{api_key}"}], receive_timeout: 15_000) do
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
    remaining = model["current_interval_usage_count"] || 0
    total = model["current_interval_total_count"] || 0
    used = total - remaining

    weekly_remaining = model["weekly_usage_count"] || 0
    weekly_total = model["weekly_total_count"] || 0
    weekly_used = weekly_total - weekly_remaining

    %{
      name: model["model_name"],
      used: used,
      total: total,
      remaining: remaining,
      next_reset: parse_timestamp(model["next_reset_time"]),
      weekly_used: weekly_used,
      weekly_total: weekly_total,
      weekly_remaining: weekly_remaining
    }
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ms) when is_integer(ms) do
    DateTime.from_unix!(div(ms, 1000))
  end
end
