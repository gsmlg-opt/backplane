defmodule Backplane.Settings.OAuthClient do
  @moduledoc "OAuth2 client_credentials token exchange via Req."
  require Logger

  @spec exchange(map()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def exchange(
        %{"client_id" => client_id, "token_url" => token_url, "client_secret" => client_secret} =
          params
      ) do
    body = %{
      "grant_type" => "client_credentials",
      "client_id" => client_id,
      "client_secret" => client_secret
    }

    body = if params["scope"], do: Map.put(body, "scope", params["scope"]), else: body
    body = if params["audience"], do: Map.put(body, "audience", params["audience"]), else: body

    case Req.post(token_url, form: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"access_token" => token} = resp}} ->
        {:ok, token, resp["expires_in"] || 3600}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning(
          "OAuth token exchange failed: status=#{status} body=#{inspect(resp_body)}"
        )

        {:error, {:token_exchange_failed, status}}

      {:error, reason} ->
        Logger.warning("OAuth token exchange error: #{inspect(reason)}")
        {:error, {:token_exchange_error, reason}}
    end
  end
end
