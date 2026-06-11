defmodule Backplane.Monitor.UsageFetcher do
  @moduledoc """
  Dispatches usage queries to provider-specific modules.

  Decrypts the plan's credential and delegates to the appropriate provider
  module to fetch live usage data.
  """

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.Providers.{ClaudeCode, GoogleAntigravity, MiniMax, OpenAICodex, ZAI}
  alias Backplane.Settings.Encryption
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault

  @doc """
  Fetch usage data for a plan.

  Returns `{:ok, usage_data}` or `{:error, reason}`.
  """
  @spec fetch_usage(Plan.t()) :: {:ok, map()} | {:error, term()}
  def fetch_usage(%Plan{provider: "openai_codex"} = plan) do
    if Plan.provider_supported?("openai_codex") do
      fetch_openai_codex_usage(plan)
    else
      {:error, :provider_not_supported}
    end
  end

  def fetch_usage(%Plan{provider: "claude_code"} = plan) do
    if Plan.provider_supported?("claude_code") do
      fetch_claude_code_usage(plan)
    else
      {:error, :provider_not_supported}
    end
  end

  def fetch_usage(%Plan{provider: "google_ai"} = plan) do
    if Plan.provider_supported?("google_ai") do
      fetch_google_antigravity_usage(plan)
    else
      {:error, :provider_not_supported}
    end
  end

  def fetch_usage(%Plan{provider: provider} = plan) do
    if Plan.provider_supported?(provider) do
      with {:ok, credential} <- fetch_credential(provider, plan.credential_name) do
        fetch_provider(provider, credential, plan.config)
      end
    else
      {:error, :provider_not_supported}
    end
  end

  defp fetch_credential(_provider, credential_name), do: Credentials.fetch(credential_name)

  defp fetch_claude_code_usage(%Plan{credential_name: credential_name, config: config}) do
    with {:ok, credential_type} <- claude_code_credential_type(credential_name),
         {:ok, credential} <- Credentials.fetch(credential_name) do
      case credential_type do
        :anthropic_oauth -> ClaudeCode.fetch_oauth(credential, config || %{})
        :script -> ClaudeCode.fetch(credential, config || %{})
      end
    end
  end

  defp claude_code_credential_type(credential_name) do
    case Vault.get(credential_name) do
      nil ->
        {:error, :not_found}

      %{metadata: %{"auth_type" => "anthropic_oauth"}} ->
        {:ok, :anthropic_oauth}

      %{kind: "script"} ->
        {:ok, :script}

      %{kind: "llm", metadata: metadata} ->
        auth_type = (metadata || %{})["auth_type"] || "api_key"
        {:error, {:invalid_credential_auth_type, auth_type, "anthropic_oauth"}}

      %{kind: kind} ->
        {:error, {:invalid_credential_kind, kind, "script or anthropic_oauth"}}
    end
  end

  defp fetch_openai_codex_usage(%Plan{credential_name: credential_name, config: config}) do
    with {:ok, credential} <- openai_codex_credential(credential_name),
         :ok <- refresh_openai_codex_if_due(credential_name),
         {:ok, credential} <- openai_codex_credential(credential.name),
         {:ok, access_token} <- Credentials.fetch(credential_name) do
      config = openai_codex_config(config || %{}, credential)

      case OpenAICodex.fetch(access_token, config) do
        {:error, :unauthorized} -> retry_openai_codex_usage(credential_name, config)
        result -> result
      end
    end
  end

  defp openai_codex_credential(credential_name) do
    case Vault.get(credential_name) do
      nil ->
        {:error, :not_found}

      %{metadata: %{"auth_type" => "openai_oauth"}} = credential ->
        {:ok, credential}

      %{metadata: metadata} ->
        auth_type = (metadata || %{})["auth_type"] || "api_key"
        {:error, {:invalid_credential_auth_type, auth_type, "openai_oauth"}}
    end
  end

  defp refresh_openai_codex_if_due(credential_name) do
    case Credentials.refresh_oauth_token(credential_name) do
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_openai_codex_usage(credential_name, config) do
    Credentials.invalidate_token(credential_name)

    with {:ok, _status} <-
           Credentials.refresh_oauth_token(credential_name, refresh_interval_ms: 0),
         {:ok, access_token} <- Credentials.fetch(credential_name) do
      OpenAICodex.fetch(access_token, config)
    end
  end

  defp fetch_google_antigravity_usage(%Plan{credential_name: credential_name, config: config}) do
    with {:ok, _credential} <- google_antigravity_credential(credential_name),
         :ok <- refresh_google_antigravity_if_due(credential_name),
         {:ok, access_token} <- Credentials.fetch(credential_name) do
      config = config || %{}

      case GoogleAntigravity.fetch(access_token, config) do
        {:error, :unauthorized} -> retry_google_antigravity_usage(credential_name, config)
        result -> result
      end
    end
  end

  defp google_antigravity_credential(credential_name) do
    case Vault.get(credential_name) do
      nil ->
        {:error, :not_found}

      %{metadata: %{"auth_type" => "google_oauth"}} = credential ->
        {:ok, credential}

      %{metadata: metadata} ->
        auth_type = (metadata || %{})["auth_type"] || "api_key"
        {:error, {:invalid_credential_auth_type, auth_type, "google_oauth"}}
    end
  end

  defp refresh_google_antigravity_if_due(credential_name) do
    case Credentials.refresh_oauth_token(credential_name) do
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_google_antigravity_usage(credential_name, config) do
    Credentials.invalidate_token(credential_name)

    with {:ok, _status} <-
           Credentials.refresh_oauth_token(credential_name, refresh_interval_ms: 0, force: true),
         {:ok, access_token} <- Credentials.fetch(credential_name) do
      GoogleAntigravity.fetch(access_token, config)
    end
  end

  defp openai_codex_config(config, credential) do
    metadata = credential.metadata || %{}

    account_id =
      config_value(config, "chatgpt_account_id") ||
        config_value(config, "account_id") ||
        config_value(metadata, "account_id") ||
        config_value(metadata, "chatgpt_account_id") ||
        openai_codex_account_id_from_blob(credential)

    maybe_put_missing(config, "chatgpt_account_id", account_id)
  end

  defp openai_codex_account_id_from_blob(%{encrypted_value: encrypted}) do
    with {:ok, raw} <- Encryption.decrypt(encrypted),
         {:ok, tokens} when is_map(tokens) <- Jason.decode(raw) do
      account_id_from_tokens(tokens)
    else
      _ -> nil
    end
  end

  defp account_id_from_tokens(tokens) do
    config_value(tokens, "chatgpt_account_id") ||
      config_value(tokens, "account_id") ||
      tokens
      |> config_value("tokens")
      |> account_id_from_wrapped_tokens() ||
      account_id_from_token_claims(tokens)
  end

  defp account_id_from_wrapped_tokens(tokens) when is_map(tokens) do
    config_value(tokens, "chatgpt_account_id") ||
      config_value(tokens, "account_id") ||
      account_id_from_token_claims(tokens)
  end

  defp account_id_from_wrapped_tokens(_), do: nil

  defp account_id_from_token_claims(tokens) when is_map(tokens) do
    tokens
    |> token_claim_sources()
    |> Enum.find_value(fn token ->
      token
      |> decode_jwt_claims()
      |> first_deep_claim(["chatgpt_account_id", "account_id"])
    end)
  end

  defp token_claim_sources(tokens) do
    [
      config_value(tokens, "id_token"),
      config_value(tokens, "access_token")
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp decode_jwt_claims(token) when is_binary(token) do
    with [_header, payload | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      claims
    else
      _ -> %{}
    end
  end

  defp first_deep_claim(map, keys) when is_map(map) do
    Enum.find_value(keys, &config_value(map, &1)) ||
      map
      |> Map.values()
      |> Enum.find_value(&first_deep_claim(&1, keys))
  end

  defp first_deep_claim(list, keys) when is_list(list) do
    Enum.find_value(list, &first_deep_claim(&1, keys))
  end

  defp first_deep_claim(_, _keys), do: nil

  defp maybe_put_missing(config, _key, nil), do: config

  defp maybe_put_missing(config, key, value) do
    if config_value(config, key) do
      config
    else
      Map.put(config, key, value)
    end
  end

  defp config_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = String.to_atom(key)
        Map.get(map, atom_key)
    end
  end

  defp fetch_provider("zai", api_key, config), do: ZAI.fetch(api_key, config)
  defp fetch_provider("minimax", api_key, config), do: MiniMax.fetch(api_key, config)
  defp fetch_provider(_, _, _), do: {:error, :provider_not_supported}
end
