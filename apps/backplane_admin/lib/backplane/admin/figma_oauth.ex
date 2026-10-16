defmodule Backplane.Admin.FigmaOAuth do
  @moduledoc false

  alias Backplane.Settings.{Credentials, OAuthRefresher, OAuthStateStore}

  @request_timeout_ms 30_000

  @spec complete_callback_url(String.t()) :: {:ok, term()} | {:error, term()}
  def complete_callback_url(callback_url) when is_binary(callback_url) do
    with {:ok, uri, params} <- parse_callback_url(callback_url),
         state when is_binary(state) <- non_empty(params["state"]),
         {:ok, attrs} <- pop_state(state),
         :ok <- validate_callback(attrs, uri),
         {:ok, code} <- callback_code(params),
         {:ok, credential} <- complete_popped(code, attrs) do
      {:ok, credential}
    else
      nil -> {:error, :missing_figma_callback_state}
      {:error, _reason} = error -> error
    end
  end

  @spec complete_popped(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def complete_popped(
        code,
        %{
          "vendor" => "figma_oauth",
          "cred_name" => cred_name,
          "code_verifier" => code_verifier,
          "redirect_uri" => redirect_uri
        } = attrs
      )
      when is_binary(code) and is_binary(cred_name) and is_binary(code_verifier) and
             is_binary(redirect_uri) do
    with {:ok, oauth_client} <- figma_oauth_client(attrs),
         {:ok, tokens} <- exchange_code(code, code_verifier, redirect_uri, attrs, oauth_client) do
      case Credentials.store_oauth_token(cred_name, "figma_oauth", tokens, "upstream", %{}) do
        {:ok, credential} ->
          Backplane.Admin.Audit.record("credential.oauth_connect", "credential", credential.id)
          {:ok, credential}

        {:error, reason} ->
          {:error, {:credential_store_failed, reason}}
      end
    end
  end

  def complete_popped(_code, _attrs), do: {:error, :invalid_figma_oauth_state}

  @spec format_error(term()) :: String.t()
  def format_error(:invalid_figma_callback_url), do: "Paste the full Figma callback URL"
  def format_error(:missing_figma_callback_state), do: "The callback URL is missing state"
  def format_error(:missing_figma_callback_code), do: "The callback URL is missing code"

  def format_error(:figma_callback_redirect_mismatch),
    do: "The callback URL does not match this login"

  def format_error(:invalid_figma_oauth_state),
    do: "OAuth state expired or invalid. Please try again."

  def format_error(:invalid_figma_oauth_client),
    do: "The Figma OAuth client is invalid; reconnect"

  def format_error(:invalid_figma_token_response),
    do: "Figma returned an incomplete token response"

  def format_error({:credential_store_failed, _reason}),
    do: "Auth succeeded but failed to save the credential"

  def format_error({:provider_error, error, description}) do
    [description, error]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" (")
    |> then(fn
      "" -> "Figma denied authorization"
      message when is_binary(description) and is_binary(error) -> message <> ")"
      message -> message
    end)
  end

  def format_error({:http, status, %{"error_description" => description}}),
    do: "#{description} (#{status})"

  def format_error({:http, status, %{"error" => error}}), do: "#{error} (#{status})"
  def format_error({:http, status, _body}), do: "HTTP #{status}"
  def format_error(reason), do: inspect(reason)

  defp parse_callback_url(callback_url) do
    with {:ok, uri} <- URI.new(String.trim(callback_url)),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo) and is_nil(uri.fragment),
         {:ok, params} <- decode_query(uri.query) do
      {:ok, uri, params}
    else
      _ -> {:error, :invalid_figma_callback_url}
    end
  end

  defp decode_query(query) when is_binary(query) do
    try do
      {:ok, URI.decode_query(query)}
    rescue
      ArgumentError -> {:error, :invalid_figma_callback_url}
    end
  end

  defp decode_query(_query), do: {:error, :invalid_figma_callback_url}

  defp pop_state(state) do
    case OAuthStateStore.pop(state) do
      {:ok, attrs} -> {:ok, attrs}
      :error -> {:error, :invalid_figma_oauth_state}
    end
  end

  defp validate_callback(%{"vendor" => "figma_oauth", "redirect_uri" => redirect_uri}, uri) do
    expected = URI.parse(redirect_uri)

    if {uri.scheme, uri.host, uri.port, uri.path} ==
         {expected.scheme, expected.host, expected.port, expected.path} do
      :ok
    else
      {:error, :figma_callback_redirect_mismatch}
    end
  end

  defp validate_callback(_attrs, _uri), do: {:error, :invalid_figma_oauth_state}

  defp callback_code(%{"error" => error} = params) do
    {:error, {:provider_error, non_empty(error), non_empty(params["error_description"])}}
  end

  defp callback_code(params) do
    case non_empty(params["code"]) do
      nil -> {:error, :missing_figma_callback_code}
      code -> {:ok, code}
    end
  end

  defp figma_oauth_client(%{"oauth_client" => client}) do
    if OAuthRefresher.valid_figma_client_context?(client),
      do: {:ok, client},
      else: {:error, :invalid_figma_oauth_client}
  end

  defp figma_oauth_client(%{"redirect_uri" => redirect_uri}) do
    with {:ok, client, _persist?} <- OAuthRefresher.resolve_figma_mcp_client(redirect_uri) do
      {:ok, client}
    end
  end

  defp exchange_code(code, code_verifier, redirect_uri, attrs, oauth_client) do
    with {:ok, headers, auth_body} <- OAuthRefresher.figma_client_auth(oauth_client) do
      token_url = OAuthRefresher.figma_token_url()

      body =
        Map.merge(
          %{
            "grant_type" => "authorization_code",
            "code" => code,
            "redirect_uri" => redirect_uri,
            "code_verifier" => code_verifier,
            "resource" => OAuthRefresher.figma_resource()
          },
          auth_body
        )

      request_options =
        token_url
        |> OAuthRefresher.request_options()
        |> Keyword.merge(form: body, headers: headers, receive_timeout: @request_timeout_ms)

      case Req.post(token_url, request_options) do
        {:ok, %{status: 200, body: response}} ->
          normalize_tokens(response, attrs, oauth_client)

        {:ok, %{status: status, body: response}} ->
          {:error, {:http, status, sanitized_oauth_error(response)}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp normalize_tokens(
         %{
           "access_token" => access_token,
           "refresh_token" => refresh_token,
           "expires_in" => expires_in
         },
         attrs,
         oauth_client
       )
       when is_binary(access_token) and is_binary(refresh_token) and
              is_integer(expires_in) and expires_in > 0 do
    if String.trim(access_token) == "" or String.trim(refresh_token) == "" do
      {:error, :invalid_figma_token_response}
    else
      tokens = %{
        access_token: access_token,
        refresh_token: refresh_token,
        expires_at: System.system_time(:millisecond) + expires_in * 1_000
      }

      tokens =
        if attrs["persist_oauth_client"],
          do: Map.put(tokens, :oauth_client, oauth_client),
          else: tokens

      {:ok, tokens}
    end
  end

  defp normalize_tokens(_response, _attrs, _oauth_client),
    do: {:error, :invalid_figma_token_response}

  defp sanitized_oauth_error(response) when is_map(response) do
    Map.take(response, ["error", "error_description"])
  end

  defp sanitized_oauth_error(_response), do: %{}

  defp non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty(_value), do: nil
end
