defmodule Backplane.Monitor.Providers.ZAI do
  @moduledoc """
  Fetches usage data from the z.ai (Zhipu/BigModel) API.

  Endpoint: `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`
  Auth: Bearer token

  Response shape:
  ```json
  {
    "data": {
      "limits": [
        {
          "type": "TOKENS_LIMIT",
          "unit": 3,
          "number": 5,
          "percentage": 1,
          "nextResetTime": 1748390460000,
          "usageDetails": [...]
        },
        {
          "type": "TIME_LIMIT",
          "unit": 5,
          "number": 1,
          "percentage": 0,
          "remaining": 100,
          "nextResetTime": 1748441820000,
          "usageDetails": [...]
        }
      ]
    }
  }
  ```
  """

  @default_url "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

  @doc "Fetch z.ai usage quota data."
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

  defp parse_response(%{"data" => %{"limits" => limits}}) when is_list(limits) do
    %{
      provider: "zai",
      limits: Enum.map(limits, &parse_limit/1)
    }
  end

  defp parse_response(body) do
    %{provider: "zai", limits: [], raw: body}
  end

  defp parse_limit(limit) do
    %{
      type: limit["type"],
      unit: limit["unit"],
      number: limit["number"],
      percentage: limit["percentage"],
      remaining: limit["remaining"],
      next_reset: parse_timestamp(limit["nextResetTime"]),
      details: parse_details(limit["usageDetails"])
    }
  end

  defp parse_details(nil), do: []

  defp parse_details(details) when is_list(details) do
    Enum.map(details, fn detail ->
      %{
        model_code: detail["modelCode"],
        tool_name: detail["toolName"] || detail["modelCode"],
        used: detail["used"] || detail["currentUsed"] || 0
      }
    end)
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ms) when is_integer(ms) do
    DateTime.from_unix!(div(ms, 1000))
  end
end
