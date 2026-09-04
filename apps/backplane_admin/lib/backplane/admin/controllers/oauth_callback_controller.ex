defmodule Backplane.Admin.OAuthCallbackController do
  @moduledoc """
  Handles the OAuth 2.0 authorization-code callback for Anthropic, OpenAI, Google, and Figma.

  After the user authenticates in their browser the provider redirects to
  GET /oauth/callback?code=…&state=… which this controller handles.
  """

  use Backplane.Admin, :controller

  require Logger

  alias Backplane.Settings.{Credentials, OAuthRefresher, OAuthStateStore}

  @anthropic_token_url "https://platform.claude.com/v1/oauth/token"
  @openai_token_url "https://auth0.openai.com/oauth/token"

  @anthropic_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @openai_client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @google_token_url "https://oauth2.googleapis.com/token"
  @request_timeout_ms 30_000

  def callback(conn, %{"code" => code, "state" => state}) do
    case OAuthStateStore.pop(state) do
      {:ok,
       %{
         "vendor" => vendor,
         "cred_name" => cred_name,
         "code_verifier" => code_verifier,
         "redirect_uri" => redirect_uri
       } = attrs} ->
        attrs = Map.put(attrs, "oauth_state", state)

        case exchange_code(vendor, code, code_verifier, redirect_uri, attrs) do
          {:ok, tokens, hints} ->
            case store_callback_tokens(cred_name, vendor, tokens, hints) do
              {:ok, _} ->
                conn
                |> put_flash(:info, "Connected #{vendor_label(vendor)} as '#{cred_name}'")
                |> redirect(to: ~p"/system/credentials")

              {:error, reason} ->
                Logger.warning("OAuth credential store failed: #{inspect(reason)}")

                conn
                |> put_flash(:error, "Auth succeeded but failed to save credential")
                |> redirect(to: ~p"/system/credentials")
            end

          {:error, reason} ->
            Logger.warning("OAuth code exchange failed: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Authorization failed: #{format_error(reason)}")
            |> redirect(to: ~p"/system/credentials")
        end

      :error ->
        conn
        |> put_flash(:error, "OAuth state expired or invalid. Please try again.")
        |> redirect(to: ~p"/system/credentials")
    end
  end

  def callback(conn, %{"error" => error, "error_description" => desc}) do
    conn
    |> put_flash(:error, "Authorization denied: #{desc} (#{error})")
    |> redirect(to: ~p"/system/credentials")
  end

  def callback(conn, %{"error" => error}) do
    conn
    |> put_flash(:error, "Authorization denied: #{error}")
    |> redirect(to: ~p"/system/credentials")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid OAuth callback — missing code or state")
    |> redirect(to: ~p"/system/credentials")
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp store_callback_tokens(name, "figma_oauth", tokens, hints) do
    Credentials.store_oauth_token(name, "figma_oauth", tokens, "upstream", hints)
  end

  defp store_callback_tokens(name, vendor, tokens, hints) do
    Credentials.store_device_token(name, vendor, tokens, hints)
  end

  defp exchange_code("anthropic_oauth", code, code_verifier, redirect_uri, attrs) do
    body = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "state" => attrs["oauth_state"],
      "redirect_uri" => redirect_uri,
      "client_id" => @anthropic_client_id,
      "code_verifier" => code_verifier
    }

    case Req.post(@anthropic_token_url,
           json: body,
           headers: OAuthRefresher.anthropic_oauth_token_headers(),
           receive_timeout: @request_timeout_ms
         ) do
      {:ok, %{status: 200, body: resp}} ->
        access = resp["access_token"] || resp["api_key"]
        refresh = resp["refresh_token"] || ""
        expires_in = resp["expires_in"] || 3600
        expires_at = System.system_time(:millisecond) + expires_in * 1_000

        tokens = %{access_token: access, refresh_token: refresh, expires_at: expires_at}
        hints = build_anthropic_hints(resp)
        {:ok, tokens, hints}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp exchange_code("openai_oauth", code, code_verifier, redirect_uri, _attrs) do
    body = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "client_id" => @openai_client_id,
      "code_verifier" => code_verifier
    }

    case Req.post(@openai_token_url, form: body, receive_timeout: @request_timeout_ms) do
      {:ok, %{status: 200, body: resp}} ->
        access = resp["access_token"]
        refresh = resp["refresh_token"] || ""
        expires_in = resp["expires_in"] || 3600
        expires_at = System.system_time(:millisecond) + expires_in * 1_000

        tokens = %{access_token: access, refresh_token: refresh, expires_at: expires_at}
        hints = build_openai_hints(resp)
        {:ok, tokens, hints}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp exchange_code("google_oauth", code, code_verifier, redirect_uri, _attrs) do
    with {:ok, client_id, client_secret} <- google_client_credentials() do
      body =
        %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client_id,
          "code_verifier" => code_verifier
        }
        |> maybe_put("client_secret", client_secret)

      case Req.post(google_token_url(), form: body, receive_timeout: @request_timeout_ms) do
        {:ok, %{status: 200, body: resp}} ->
          access = resp["access_token"]
          refresh = resp["refresh_token"] || ""
          expires_in = resp["expires_in"] || 3600
          expires_at = System.system_time(:millisecond) + expires_in * 1_000

          tokens = %{access_token: access, refresh_token: refresh, expires_at: expires_at}
          hints = build_google_hints(resp)
          {:ok, tokens, hints}

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp exchange_code("figma_oauth", code, code_verifier, redirect_uri, _attrs) do
    with {:ok, headers} <- OAuthRefresher.figma_mcp_client_auth_headers() do
      token_url = OAuthRefresher.figma_token_url()

      body = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "code_verifier" => code_verifier,
        "resource" => OAuthRefresher.figma_resource()
      }

      request_options =
        token_url
        |> OAuthRefresher.request_options()
        |> Keyword.merge(form: body, headers: headers, receive_timeout: @request_timeout_ms)

      case Req.post(token_url, request_options) do
        {:ok, %{status: 200, body: response}} ->
          normalize_figma_tokens(response)

        {:ok, %{status: status, body: response}} ->
          {:error, {:http, status, sanitized_oauth_error(response)}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp exchange_code(vendor, _code, _code_verifier, _redirect_uri, _attrs) do
    {:error, {:unsupported_vendor, vendor}}
  end

  defp normalize_figma_tokens(%{
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "expires_in" => expires_in
       })
       when is_binary(access_token) and is_binary(refresh_token) and
              is_integer(expires_in) and expires_in > 0 do
    if String.trim(access_token) == "" or String.trim(refresh_token) == "" do
      {:error, :invalid_figma_token_response}
    else
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_at: System.system_time(:millisecond) + expires_in * 1_000
       }, %{}}
    end
  end

  defp normalize_figma_tokens(_response), do: {:error, :invalid_figma_token_response}

  defp sanitized_oauth_error(response) when is_map(response) do
    Map.take(response, ["error", "error_description"])
  end

  defp sanitized_oauth_error(_response), do: %{}

  defp build_anthropic_hints(resp) do
    %{}
    |> maybe_put("subscription_type", resp["subscription_type"] || resp["plan"])
    |> maybe_put("organization_uuid", resp["organization_uuid"] || resp["org_id"])
  end

  defp build_openai_hints(resp) do
    %{}
    |> maybe_put("account_id", resp["account_id"])
  end

  defp build_google_hints(resp) do
    %{"auth_mode" => "antigravity"}
    |> maybe_put(
      "email",
      get_in(resp, ["id_token"]) && decode_email_from_id_token(resp["id_token"])
    )
  end

  defp decode_email_from_id_token(nil), do: nil

  defp decode_email_from_id_token(id_token) do
    with [_, payload_b64 | _] <- String.split(id_token, "."),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, payload} <- Jason.decode(payload_json) do
      payload["email"]
    else
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp google_client_credentials do
    client_id =
      google_oauth_value(
        :google_client_id,
        "GOOGLE_OAUTH_CLIENT_ID",
        OAuthRefresher.google_antigravity_client_id()
      )

    client_secret =
      google_oauth_value(
        :google_client_secret,
        "GOOGLE_OAUTH_CLIENT_SECRET",
        default_google_client_secret(client_id)
      )

    if client_id,
      do: {:ok, client_id, client_secret},
      else: {:error, :missing_google_oauth_client_id}
  end

  defp google_token_url do
    google_oauth_value(:google_token_url, nil, @google_token_url)
  end

  defp default_google_client_secret(client_id) do
    if client_id == OAuthRefresher.google_antigravity_client_id() do
      OAuthRefresher.google_antigravity_client_secret()
    end
  end

  defp google_oauth_value(key, env_key, default) do
    [
      :backplane
      |> Application.get_env(Backplane.Settings.OAuthRefresher, [])
      |> Keyword.get(key),
      env_key && System.get_env(env_key),
      default
    ]
    |> Enum.find_value(&normalize_optional_string/1)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_string(_), do: nil

  defp vendor_label("anthropic_oauth"), do: "Claude Plan"
  defp vendor_label("openai_oauth"), do: "OpenAI Codex"
  defp vendor_label("google_oauth"), do: "Google Antigravity"
  defp vendor_label("figma_oauth"), do: "Figma MCP"
  defp vendor_label(v), do: v

  defp format_error(:missing_figma_mcp_client_id),
    do: "FIGMA_MCP_CLIENT_ID is not configured"

  defp format_error(:missing_figma_mcp_client_secret),
    do: "FIGMA_MCP_CLIENT_SECRET is not configured"

  defp format_error(:invalid_figma_token_response),
    do: "Figma returned an incomplete token response"

  defp format_error({:http, status, %{"error_description" => desc}}), do: "#{desc} (#{status})"

  defp format_error({:http, status, %{"error" => %{"message" => message, "type" => type}}}),
    do: "#{message} (#{type}, #{status})"

  defp format_error({:http, status, %{"error" => %{"message" => message}}}),
    do: "#{message} (#{status})"

  defp format_error({:http, status, %{"error" => err}}), do: "#{err} (#{status})"
  defp format_error({:http, status, _}), do: "HTTP #{status}"
  defp format_error(other), do: inspect(other)
end
