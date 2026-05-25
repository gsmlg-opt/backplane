defmodule Backplane.Settings.OAuthDeviceFlow do
  @moduledoc """
  OAuth 2.0 Device Authorization Grant (RFC 8628) for three AI plan providers.

  Supported vendors:
  - `:anthropic_oauth` — Claude Plan (console.anthropic.com)
  - `:openai_oauth`   — OpenAI Codex (auth.openai.com)
  - `:google_oauth`   — Google AI (oauth2.googleapis.com)

  Usage:
    1. Call `request_device_code/2` to get `user_code` + `verification_uri`.
    2. Show those to the user so they can authorise in a browser.
    3. Call `poll/3` repeatedly (at `interval` seconds) until it returns
       `{:ok, tokens}`, `{:expired}`, or `{:error, reason}`.
  """

  require Logger

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @type vendor :: :anthropic_oauth | :openai_oauth | :google_oauth
  @type device_code_response :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          expires_in: integer(),
          interval: integer()
        }
  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t(),
          expires_at: integer()
        }

  @doc """
  Request a device code from the provider.

  For `:google_oauth`, pass `client_id` in opts:
    `request_device_code(:google_oauth, client_id: "my-client.apps.googleusercontent.com")`
  """
  @spec request_device_code(vendor(), keyword()) ::
          {:ok, device_code_response()} | {:error, term()}
  def request_device_code(:anthropic_oauth, _opts) do
    url = cfg(:anthropic_device_url)

    post_form(url, %{
      "client_id" => @anthropic_client_id,
      "scope" => "user:inference user:profile"
    })
    |> parse_device_code_response()
  end

  def request_device_code(:openai_oauth, _opts) do
    url = cfg(:openai_device_url)

    post_form(url, %{
      "client_id" => @openai_client_id,
      "scope" => "openid profile email offline_access"
    })
    |> parse_device_code_response()
  end

  def request_device_code(:google_oauth, opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    url = cfg(:google_device_url)

    post_form(url, %{
      "client_id" => client_id,
      "scope" => "https://www.googleapis.com/auth/generativelanguage"
    })
    |> parse_device_code_response()
  end

  @doc """
  Poll the token endpoint for a completed device authorisation.

  Returns:
  - `{:ok, tokens}` — user completed; tokens ready to store
  - `{:pending}` — user hasn't authorised yet; retry after `interval` seconds
  - `{:slow_down}` — back off; retry after `interval + 5` seconds
  - `{:expired}` — device code expired; restart the flow
  - `{:error, reason}` — unrecoverable error
  """
  @spec poll(vendor(), String.t(), keyword()) ::
          {:ok, tokens()} | {:pending} | {:slow_down} | {:expired} | {:error, term()}
  def poll(:anthropic_oauth, device_code, _opts) do
    url = cfg(:anthropic_token_url)

    post_json(url, %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => device_code,
      "client_id" => @anthropic_client_id
    })
    |> parse_poll_response()
  end

  def poll(:openai_oauth, device_code, _opts) do
    url = cfg(:openai_token_url)

    post_form(url, %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => device_code,
      "client_id" => @openai_client_id
    })
    |> parse_poll_response()
  end

  def poll(:google_oauth, device_code, opts) do
    client_id = Keyword.fetch!(opts, :client_id)
    client_secret = Keyword.get(opts, :client_secret, "")
    url = cfg(:google_token_url)

    post_form(url, %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => device_code,
      "client_id" => client_id,
      "client_secret" => client_secret
    })
    |> parse_poll_response()
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp post_form(url, body) do
    Req.post(url, form: body, receive_timeout: 15_000)
  end

  defp post_json(url, body) do
    Req.post(url, json: body, receive_timeout: 15_000)
  end

  defp parse_device_code_response({:ok, %{status: 200, body: body}}) do
    with %{
           "device_code" => device_code,
           "user_code" => user_code,
           "verification_uri" => verification_uri
         } <- body do
      {:ok,
       %{
         device_code: device_code,
         user_code: user_code,
         verification_uri: Map.get(body, "verification_url") || verification_uri,
         expires_in: Map.get(body, "expires_in", 1800),
         interval: Map.get(body, "interval", 5)
       }}
    else
      _ -> {:error, {:unexpected_response, body}}
    end
  end

  defp parse_device_code_response({:ok, %{status: status, body: body}}) do
    Logger.warning("Device code request failed: status=#{status} body=#{inspect(body)}")
    {:error, {:request_failed, status}}
  end

  defp parse_device_code_response({:error, reason}) do
    Logger.warning("Device code request error: #{inspect(reason)}")
    {:error, {:transport_error, reason}}
  end

  defp parse_poll_response({:ok, %{status: 200, body: %{"access_token" => access} = body}}) do
    expires_in = body["expires_in"] || 3600
    expires_at = System.system_time(:millisecond) + expires_in * 1000

    {:ok,
     %{
       access_token: access,
       refresh_token: body["refresh_token"] || "",
       expires_at: expires_at
     }}
  end

  defp parse_poll_response({:ok, %{status: _, body: %{"error" => "authorization_pending"}}}),
    do: {:pending}

  defp parse_poll_response({:ok, %{status: _, body: %{"error" => "slow_down"}}}),
    do: {:slow_down}

  defp parse_poll_response({:ok, %{status: _, body: %{"error" => "expired_token"}}}),
    do: {:expired}

  defp parse_poll_response({:ok, %{status: _, body: %{"error" => "access_denied"}}}),
    do: {:error, :access_denied}

  defp parse_poll_response({:ok, %{status: status, body: body}}) do
    Logger.warning("Device code poll failed: status=#{status} body=#{inspect(body)}")
    {:error, {:poll_failed, status}}
  end

  defp parse_poll_response({:error, reason}) do
    Logger.warning("Device code poll error: #{inspect(reason)}")
    {:error, {:transport_error, reason}}
  end

  defp cfg(key) do
    Application.get_env(:backplane, __MODULE__, [])
    |> Keyword.get(key, default_url(key))
  end

  defp default_url(:anthropic_device_url),
    do: "https://console.anthropic.com/v1/oauth/device/code"

  defp default_url(:anthropic_token_url),
    do: "https://console.anthropic.com/v1/oauth/token"

  defp default_url(:openai_device_url),
    do: "https://auth.openai.com/oauth/device/code"

  defp default_url(:openai_token_url),
    do: "https://auth.openai.com/oauth/token"

  defp default_url(:google_device_url),
    do: "https://oauth2.googleapis.com/device/code"

  defp default_url(:google_token_url),
    do: "https://oauth2.googleapis.com/token"
end
