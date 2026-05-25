defmodule Backplane.Settings.OAuthRefresher do
  @moduledoc """
  OAuth refresh-token exchange for AI plan credential formats.

  Supported vendors:
  - `:anthropic_oauth` — Claude Plan (console.anthropic.com)
  - `:openai_oauth`   — OpenAI Codex (auth.openai.com)
  - `:google_oauth`   — Google AI (oauth2.googleapis.com); requires client_id/secret in metadata

  Pure function. Does not touch the DB or cache. The caller (`Credentials`)
  persists rotated tokens.
  """

  require Logger

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @type vendor :: :anthropic_oauth | :openai_oauth | :google_oauth
  @type refreshed :: %{
          required(:access_token) => String.t(),
          required(:refresh_token) => String.t(),
          required(:expires_at) => integer(),
          optional(:id_token) => String.t()
        }

  @spec refresh(vendor(), String.t(), keyword()) :: {:ok, refreshed()} | {:error, term()}
  def refresh(vendor, refresh_token, opts \\ [])

  def refresh(:anthropic_oauth, refresh_token, _opts) when is_binary(refresh_token) do
    do_refresh(
      url(:anthropic_token_url),
      :json,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @anthropic_client_id
      }
    )
  end

  def refresh(:openai_oauth, refresh_token, _opts) when is_binary(refresh_token) do
    do_refresh(
      url(:openai_token_url),
      :form,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @openai_client_id
      }
    )
  end

  def refresh(:google_oauth, refresh_token, opts) when is_binary(refresh_token) do
    client_id = Keyword.fetch!(opts, :client_id)
    client_secret = Keyword.get(opts, :client_secret, "")

    do_refresh(
      url(:google_token_url),
      :form,
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => client_id,
        "client_secret" => client_secret
      }
    )
  end

  defp do_refresh(url, encoding, body) do
    req_opts = [{encoding, body}, {:receive_timeout, 10_000}]

    case Req.post(url, req_opts) do
      {:ok, %{status: 200, body: %{"access_token" => access} = resp}} ->
        expires_in = resp["expires_in"] || 3600
        refresh = resp["refresh_token"] || body["refresh_token"]
        expires_at = System.system_time(:millisecond) + expires_in * 1000

        result = %{access_token: access, refresh_token: refresh, expires_at: expires_at}

        result =
          if resp["id_token"], do: Map.put(result, :id_token, resp["id_token"]), else: result

        {:ok, result}

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("OAuth refresh failed: status=#{status} body=#{inspect(resp_body)}")
        {:error, {:refresh_failed, status}}

      {:error, reason} ->
        Logger.warning("OAuth refresh transport error: #{inspect(reason)}")
        {:error, {:refresh_error, reason}}
    end
  end

  defp url(key) do
    cfg = Application.get_env(:backplane, __MODULE__, [])
    Keyword.get(cfg, key) || default_url(key)
  end

  defp default_url(:anthropic_token_url), do: "https://console.anthropic.com/v1/oauth/token"
  defp default_url(:openai_token_url), do: "https://auth.openai.com/oauth/token"
  defp default_url(:google_token_url), do: "https://oauth2.googleapis.com/token"
end
