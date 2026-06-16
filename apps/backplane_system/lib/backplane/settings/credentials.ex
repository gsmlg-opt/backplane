defmodule Backplane.Settings.Credentials do
  @moduledoc """
  Centralized encrypted credential store. All secrets in one table,
  referenced by name everywhere else.

  - `store/4` — encrypt and upsert a credential
  - `import_cli_auth/2` — import Claude Code / Codex OAuth JSON file
  - `fetch/1` — decrypt and return plaintext (or exchange/refresh OAuth token)
  - `fetch_with_meta/1` — like fetch/1 but also returns auth_type and extra headers
  - `delete/1` — remove a credential
  - `list/0` — list credentials (never returns plaintext)
  - `exists?/1` — check if credential exists
  - `invalidate_token/1` — remove a cached OAuth2 token
  """

  alias Backplane.Repo
  alias Backplane.Settings.Credential
  alias Backplane.Settings.Credentials.Vault
  alias Backplane.Settings.Encryption

  import Ecto.Query

  @device_oauth_vendors %{
    "anthropic_oauth" => :anthropic_oauth,
    "openai_oauth" => :openai_oauth,
    "google_oauth" => :google_oauth,
    "xai_oauth" => :xai_oauth
  }
  @default_oauth_refresh_window_ms 10 * 60 * 1000
  @default_oauth_refresh_interval_ms 7 * 24 * 60 * 60 * 1000

  @doc "Store (upsert) a credential. Encrypts the plaintext value."
  @spec store(String.t(), String.t(), String.t(), map()) ::
          {:ok, Credential.t()} | {:error, term()}
  def store(name, plaintext, kind, metadata \\ %{}) do
    with :ok <- validate_oauth_metadata(metadata) do
      encrypted = Encryption.encrypt(plaintext)

      result =
        case Repo.get_by(Credential, name: name) do
          nil ->
            %Credential{}
            |> Credential.changeset(%{
              name: name,
              kind: kind,
              encrypted_value: encrypted,
              metadata: metadata
            })
            |> Repo.insert()

          existing ->
            existing
            |> Credential.changeset(%{
              kind: kind,
              encrypted_value: encrypted,
              metadata: metadata
            })
            |> Repo.update()
        end

      notify_changed(result)
      result
    end
  end

  @doc """
  Import a CLI OAuth auth file (Claude Code or Codex) into the credential store.

  The raw JSON content is encrypted as-is and stored alongside an `auth_type`
  marker in `metadata`, plus a few non-secret hints (subscription_type,
  organization_uuid for Anthropic; account_id for OpenAI).
  """
  @spec import_cli_auth(String.t(), String.t()) ::
          {:ok, Credential.t()} | {:error, :invalid_json | :unrecognized_format | term()}
  def import_cli_auth(name, raw_json) when is_binary(name) and is_binary(raw_json) do
    with {:ok, parsed} <- decode_json(raw_json),
         {:ok, auth_type, hints} <- detect_cli_format(parsed) do
      metadata = Map.merge(%{"auth_type" => auth_type}, hints)
      store(name, raw_json, "llm", metadata)
    end
  end

  @doc """
  Store a device-code-obtained OAuth token set.

  Encodes the token map as JSON, encrypts it, and stores with the given
  `auth_type` in metadata. Extra hints are stored unencrypted in metadata.
  """
  @spec store_device_token(String.t(), String.t(), map(), map()) ::
          {:ok, Credential.t()} | {:error, term()}
  def store_device_token(name, auth_type, tokens, hints \\ %{}) do
    blob = Jason.encode!(tokens)
    metadata = Map.merge(%{"auth_type" => auth_type}, hints)
    store(name, blob, "llm", metadata)
  end

  @doc "Fetch and decrypt a credential by name. For OAuth credentials, exchanges or returns a cached token."
  @spec fetch(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :decryption_failed | term()}
  def fetch(name) do
    case Vault.get(name) do
      nil ->
        {:error, :not_found}

      %Credential{metadata: %{"auth_type" => "oauth2_client_credentials"}} = cred ->
        fetch_oauth_token(cred)

      %Credential{metadata: %{"auth_type" => "anthropic_oauth"}} = cred ->
        fetch_device_oauth(cred, :anthropic_oauth)

      %Credential{metadata: %{"auth_type" => "openai_oauth"}} = cred ->
        fetch_device_oauth(cred, :openai_oauth)

      %Credential{metadata: %{"auth_type" => "google_oauth"}} = cred ->
        fetch_device_oauth(cred, :google_oauth)

      %Credential{metadata: %{"auth_type" => "xai_oauth"}} = cred ->
        fetch_device_oauth(cred, :xai_oauth)

      %Credential{encrypted_value: encrypted} ->
        Encryption.decrypt(encrypted)
    end
  end

  @doc """
  Like `fetch/1` but also returns the credential's auth_type and any
  per-vendor extra headers required (e.g. `anthropic-beta` for OAuth tokens).

  Used by `Backplane.LLM.CredentialPlug` to pick the correct header injection
  strategy.
  """
  @spec fetch_with_meta(String.t()) ::
          {:ok, String.t(),
           %{
             auth_type: String.t(),
             extra_headers: [{String.t(), String.t()}],
             metadata: map()
           }}
          | {:error, term()}
  def fetch_with_meta(name) do
    case Vault.get(name) do
      nil ->
        {:error, :not_found}

      %Credential{metadata: meta} ->
        meta = meta || %{}
        auth_type = Map.get(meta, "auth_type", "api_key")

        with {:ok, token} <- fetch(name) do
          {:ok, token,
           %{
             auth_type: auth_type,
             extra_headers: extra_headers_for(auth_type, meta),
             metadata: meta
           }}
        end
    end
  end

  @doc "Delete a credential by name."
  @spec delete(String.t()) :: :ok | {:error, :not_found | :delete_failed}
  def delete(name) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      credential ->
        case Repo.delete(credential) do
          {:ok, _} ->
            Backplane.Settings.TokenCache.invalidate(name)
            Vault.remove(name)
            Backplane.PubSubBroadcaster.broadcast_credential_changed(name)
            :ok

          {:error, _} ->
            {:error, :delete_failed}
        end
    end
  end

  @doc "List all credentials. Never returns plaintext values. Reads from the in-memory Vault."
  @spec list() :: [map()]
  def list do
    Vault.list()
  end

  @doc "Check if a credential exists by name. Reads from the in-memory Vault."
  @spec exists?(String.t()) :: boolean()
  def exists?(name) do
    Vault.exists?(name)
  end

  @doc "Rotate a credential's secret (update only the encrypted value). Invalidates any cached OAuth2 token."
  @spec rotate(String.t(), String.t()) :: {:ok, Credential.t()} | {:error, :not_found | term()}
  def rotate(name, new_plaintext) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      existing ->
        encrypted = Encryption.encrypt(new_plaintext)

        result =
          existing
          |> Credential.changeset(%{encrypted_value: encrypted})
          |> Repo.update()

        if match?({:ok, _}, result) do
          Backplane.Settings.TokenCache.invalidate(name)
          notify_changed(result)
        end

        result
    end
  end

  @doc "Invalidate a cached OAuth2 token for the given credential."
  @spec invalidate_token(String.t()) :: :ok
  def invalidate_token(name), do: Backplane.Settings.TokenCache.invalidate(name)

  @doc """
  Return device OAuth credential names whose tokens should be refreshed soon.

  OpenAI/Codex credentials refresh after seven days since `last_refresh`, with
  a 10-minute pre-expiry fallback. Existing OpenAI credentials without
  `last_refresh` are considered due once so the field can be recorded.
  """
  @spec oauth_credentials_due_for_refresh(keyword()) :: [String.t()]
  def oauth_credentials_due_for_refresh(opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    refresh_window_ms = refresh_window_ms(opts)
    refresh_interval_ms = refresh_interval_ms(opts)

    auth_types =
      normalize_auth_types(Keyword.get(opts, :auth_types, Map.keys(@device_oauth_vendors)))

    Credential
    |> Repo.all()
    |> Enum.filter(fn cred ->
      auth_type = (cred.metadata || %{})["auth_type"] || ""

      if auth_type in auth_types do
        with {:ok, vendor} <- oauth_vendor_for(cred),
             {:ok, parsed} <- decode_credential_blob(cred) do
          oauth_refresh_due?(vendor, parsed, now_ms, refresh_window_ms, refresh_interval_ms)
        else
          _ -> false
        end
      else
        false
      end
    end)
    |> Enum.map(& &1.name)
  end

  @doc """
  Refresh a single device OAuth credential if it is inside the refresh window.

  Returns `{:ok, :fresh}` when no refresh is needed, `{:ok, :refreshed}` when
  tokens were rotated, or `{:error, reason}` when the credential cannot refresh.
  """
  @spec refresh_oauth_token(String.t(), keyword()) ::
          {:ok, :fresh | :refreshed} | {:error, term()}
  def refresh_oauth_token(name, opts \\ []) when is_binary(name) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    refresh_window_ms = refresh_window_ms(opts)
    refresh_interval_ms = refresh_interval_ms(opts)
    force? = Keyword.get(opts, :force, false)

    with %Credential{} = cred <- Repo.get_by(Credential, name: name),
         {:ok, vendor} <- oauth_vendor_for(cred),
         {:ok, parsed} <- decode_credential_blob(cred) do
      if force? or
           oauth_refresh_due?(vendor, parsed, now_ms, refresh_window_ms, refresh_interval_ms) do
        case do_refresh_and_persist(
               cred,
               vendor,
               parsed,
               refresh_window_ms,
               refresh_interval_ms,
               force?
             ) do
          {:ok, _access_token} -> {:ok, :refreshed}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, :fresh}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return a non-secret summary of a device OAuth credential's stored token state.
  """
  @spec oauth_status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def oauth_status(name, opts \\ []) when is_binary(name) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    refresh_window_ms = refresh_window_ms(opts)

    with %Credential{} = cred <- Repo.get_by(Credential, name: name),
         {:ok, vendor} <- oauth_vendor_for(cred),
         {:ok, parsed} <- decode_credential_blob(cred) do
      {:ok, build_oauth_status(cred, vendor, parsed, now_ms, refresh_window_ms)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Update a credential's kind and/or metadata (not the secret)."
  @spec update(String.t(), map()) :: {:ok, Credential.t()} | {:error, :not_found | term()}
  def update(name, attrs) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      existing ->
        result =
          existing
          |> Credential.changeset(Map.take(attrs, [:kind, :metadata, "kind", "metadata"]))
          |> Repo.update()

        notify_changed(result)
        result
    end
  end

  @doc """
  Get the last 4 characters of a credential's decrypted value as a hint.
  Returns `"...xxxx"` format, or `"..."` if the value is too short. For
  OAuth-blob credentials, returns the last 4 of the live access_token.
  """
  @spec fetch_hint(String.t()) :: String.t()
  def fetch_hint(name) do
    case fetch(name) do
      {:ok, plaintext} when byte_size(plaintext) >= 4 ->
        "..." <> String.slice(plaintext, -4..-1//1)

      {:ok, _} ->
        "..."

      {:error, _} ->
        "..."
    end
  end

  # --- Private helpers ---

  defp extra_headers_for("anthropic_oauth", _meta), do: [{"anthropic-beta", "oauth-2025-04-20"}]

  defp extra_headers_for("openai_oauth", meta) do
    []
    |> maybe_header("chatgpt-account-id", meta["account_id"])
    |> maybe_header("originator", "codex_cli_rs")
  end

  defp extra_headers_for(_, _meta), do: []

  defp maybe_header(headers, _name, value) when value in [nil, ""], do: headers
  defp maybe_header(headers, name, value), do: [{name, to_string(value)} | headers]

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      {:ok, _} -> {:error, :unrecognized_format}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp detect_cli_format(%{"claudeAiOauth" => %{"refreshToken" => _} = oauth} = top) do
    hints =
      %{}
      |> maybe_put("subscription_type", oauth["subscriptionType"])
      |> maybe_put("organization_uuid", top["organizationUuid"])

    {:ok, "anthropic_oauth", hints}
  end

  defp detect_cli_format(%{"tokens" => %{"refresh_token" => _} = tokens}) do
    hints = maybe_put(%{}, "account_id", tokens["account_id"])
    {:ok, "openai_oauth", hints}
  end

  defp detect_cli_format(_), do: {:error, :unrecognized_format}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp refresh_window_ms(opts) do
    opts
    |> Keyword.get(:refresh_window_ms, @default_oauth_refresh_window_ms)
    |> parse_non_negative_integer(@default_oauth_refresh_window_ms)
  end

  defp refresh_interval_ms(opts) do
    opts
    |> Keyword.get(:refresh_interval_ms, @default_oauth_refresh_interval_ms)
    |> parse_non_negative_integer(@default_oauth_refresh_interval_ms)
  end

  defp parse_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp parse_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> default
    end
  end

  defp parse_non_negative_integer(_value, default), do: default

  defp normalize_auth_types(auth_types) do
    auth_types
    |> List.wrap()
    |> Enum.map(fn
      auth_type when is_atom(auth_type) -> Atom.to_string(auth_type)
      auth_type when is_binary(auth_type) -> auth_type
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp oauth_vendor_for(%Credential{metadata: metadata}) do
    auth_type = (metadata || %{})["auth_type"]

    case Map.fetch(@device_oauth_vendors, auth_type) do
      {:ok, vendor} -> {:ok, vendor}
      :error -> {:error, {:unsupported_oauth_auth_type, auth_type}}
    end
  end

  defp build_oauth_status(cred, vendor, parsed, now_ms, refresh_window_ms) do
    auth_type = (cred.metadata || %{})["auth_type"]
    expires_at_ms = extract_oauth_expires_at(vendor, parsed)
    has_refresh_token? = has_refresh_token_for(vendor, parsed)

    %{
      name: cred.name,
      auth_type: auth_type,
      vendor: vendor,
      status: oauth_status_value(expires_at_ms, now_ms, refresh_window_ms, has_refresh_token?),
      expires_at_ms: expires_at_ms,
      expires_at: datetime_from_ms(expires_at_ms),
      token_created_at: token_created_at(cred, parsed),
      credential_created_at: cred.inserted_at,
      credential_updated_at: cred.updated_at,
      last_refresh_at: parse_iso8601_datetime(parsed["last_refresh"]),
      has_refresh_token: has_refresh_token?
    }
  end

  defp oauth_status_value(_expires_at_ms, _now_ms, _refresh_window_ms, false),
    do: :missing_refresh_token

  defp oauth_status_value(nil, _now_ms, _refresh_window_ms, true), do: :unknown

  defp oauth_status_value(expires_at_ms, now_ms, _refresh_window_ms, true)
       when expires_at_ms <= now_ms,
       do: :expired

  defp oauth_status_value(expires_at_ms, now_ms, refresh_window_ms, true)
       when expires_at_ms <= now_ms + refresh_window_ms,
       do: :expiring_soon

  defp oauth_status_value(_expires_at_ms, _now_ms, _refresh_window_ms, true), do: :active

  defp extract_oauth_expires_at(:anthropic_oauth, %{
         "claudeAiOauth" => %{"expiresAt" => expires_at}
       }),
       do: normalize_ms(expires_at)

  defp extract_oauth_expires_at(:openai_oauth, %{"tokens" => %{"expires_at" => expires_at}}),
    do: normalize_ms(expires_at)

  defp extract_oauth_expires_at(_vendor, %{"expires_at" => expires_at}),
    do: normalize_ms(expires_at)

  defp extract_oauth_expires_at(_vendor, _parsed), do: nil

  defp normalize_ms(value) when is_integer(value), do: value

  defp normalize_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_ms(_value), do: nil

  defp datetime_from_ms(nil), do: nil

  defp datetime_from_ms(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp token_created_at(cred, parsed) do
    parse_iso8601_datetime(parsed["last_refresh"]) || cred.inserted_at
  end

  defp parse_iso8601_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_iso8601_datetime(_value), do: nil

  defp has_refresh_token_for(:anthropic_oauth, %{"claudeAiOauth" => %{"refreshToken" => rt}})
       when is_binary(rt) and rt != "",
       do: true

  defp has_refresh_token_for(:openai_oauth, %{"tokens" => %{"refresh_token" => rt}})
       when is_binary(rt) and rt != "",
       do: true

  defp has_refresh_token_for(_vendor, %{"refresh_token" => rt}) when is_binary(rt) and rt != "",
    do: true

  defp has_refresh_token_for(_vendor, _parsed), do: false

  defp decode_credential_blob(%Credential{encrypted_value: encrypted}) do
    with {:ok, blob} <- Encryption.decrypt(encrypted),
         {:ok, parsed} when is_map(parsed) <- Jason.decode(blob) do
      {:ok, parsed}
    else
      {:ok, _} -> {:error, :unrecognized_format}
      {:error, reason} -> {:error, reason}
    end
  end

  defp oauth_refresh_due?(
         :openai_oauth,
         parsed,
         now_ms,
         refresh_window_ms,
         refresh_interval_ms
       ) do
    openai_refresh_interval_due?(parsed, now_ms, refresh_interval_ms) or
      expires_soon?(parsed, now_ms, refresh_window_ms)
  end

  defp oauth_refresh_due?(
         :anthropic_oauth,
         %{"claudeAiOauth" => %{"expiresAt" => expires_at_ms}},
         now_ms,
         refresh_window_ms,
         _refresh_interval_ms
       )
       when is_integer(expires_at_ms) do
    expires_at_ms <= now_ms + refresh_window_ms
  end

  defp oauth_refresh_due?(
         _vendor,
         %{"expires_at" => expires_at_ms},
         now_ms,
         refresh_window_ms,
         _refresh_interval_ms
       )
       when is_integer(expires_at_ms) do
    expires_at_ms <= now_ms + refresh_window_ms
  end

  defp oauth_refresh_due?(
         _vendor,
         %{"refresh_token" => refresh_token},
         _now_ms,
         _window_ms,
         _refresh_interval_ms
       )
       when is_binary(refresh_token) and refresh_token != "" do
    true
  end

  defp oauth_refresh_due?(_vendor, _parsed, _now_ms, _refresh_window_ms, _refresh_interval_ms),
    do: false

  defp openai_refresh_interval_due?(parsed, now_ms, refresh_interval_ms) do
    cond do
      not has_refresh_token?(parsed) ->
        false

      is_nil(parsed["last_refresh"]) ->
        true

      true ->
        case parse_iso8601_ms(parsed["last_refresh"]) do
          {:ok, last_refresh_ms} -> last_refresh_ms <= now_ms - refresh_interval_ms
          :error -> true
        end
    end
  end

  defp expires_soon?(%{"expires_at" => expires_at_ms}, now_ms, refresh_window_ms)
       when is_integer(expires_at_ms) do
    expires_at_ms <= now_ms + refresh_window_ms
  end

  defp expires_soon?(_parsed, _now_ms, _refresh_window_ms), do: false

  defp has_refresh_token?(%{"tokens" => %{"refresh_token" => refresh_token}})
       when is_binary(refresh_token) and refresh_token != "",
       do: true

  defp has_refresh_token?(%{"refresh_token" => refresh_token})
       when is_binary(refresh_token) and refresh_token != "",
       do: true

  defp has_refresh_token?(_parsed), do: false

  defp parse_iso8601_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime, :millisecond)}
      {:error, _reason} -> :error
    end
  end

  defp parse_iso8601_ms(_value), do: :error

  defp validate_oauth_metadata(%{"auth_type" => "anthropic_oauth"}), do: :ok
  defp validate_oauth_metadata(%{"auth_type" => "openai_oauth"}), do: :ok
  defp validate_oauth_metadata(%{"auth_type" => "google_oauth"}), do: :ok
  defp validate_oauth_metadata(%{"auth_type" => "xai_oauth"}), do: :ok

  defp validate_oauth_metadata(%{"auth_type" => "oauth2_client_credentials"} = meta) do
    cond do
      !is_binary(meta["client_id"]) or meta["client_id"] == "" ->
        {:error, :missing_client_id}

      !is_binary(meta["token_url"]) or meta["token_url"] == "" ->
        {:error, :missing_token_url}

      not String.starts_with?(meta["token_url"], "https://") and
          not String.starts_with?(meta["token_url"], "http://localhost") ->
        {:error, :insecure_token_url}

      true ->
        :ok
    end
  end

  defp validate_oauth_metadata(_), do: :ok

  defp fetch_oauth_token(%Credential{name: name, encrypted_value: encrypted, metadata: meta}) do
    alias Backplane.Settings.{TokenCache, OAuthClient}

    case TokenCache.get(name) do
      {:ok, cached_token} ->
        {:ok, cached_token}

      :miss ->
        with {:ok, client_secret} <- Encryption.decrypt(encrypted),
             params = Map.put(meta, "client_secret", client_secret),
             {:ok, token, expires_in} <- OAuthClient.exchange(params) do
          TokenCache.put(name, token, expires_in)
          {:ok, token}
        end
    end
  end

  defp fetch_device_oauth(%Credential{name: name} = cred, vendor) do
    alias Backplane.Settings.TokenCache

    case TokenCache.get(name) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        with {:ok, blob} <- Encryption.decrypt(cred.encrypted_value),
             {:ok, parsed} <- Jason.decode(blob) do
          handle_device_oauth(cred, vendor, parsed)
        end
    end
  end

  # Anthropic CLI import format — check expiresAt before refreshing.
  defp handle_device_oauth(
         cred,
         :anthropic_oauth,
         %{"claudeAiOauth" => %{"accessToken" => access, "expiresAt" => expires_at_ms}} = parsed
       )
       when is_binary(access) and is_integer(expires_at_ms) do
    now_ms = System.system_time(:millisecond)

    if expires_at_ms > now_ms + 60_000 do
      cache_and_return(cred.name, access, expires_at_ms)
    else
      do_refresh_and_persist(cred, :anthropic_oauth, parsed)
    end
  end

  # Flat format (device-code obtained) — check expires_at for any vendor.
  defp handle_device_oauth(
         cred,
         vendor,
         %{"access_token" => access, "expires_at" => expires_at_ms} = parsed
       )
       when is_binary(access) and is_integer(expires_at_ms) do
    now_ms = System.system_time(:millisecond)

    if expires_at_ms > now_ms + 60_000 do
      cache_and_return(cred.name, access, expires_at_ms)
    else
      do_refresh_and_persist(cred, vendor, parsed)
    end
  end

  # OpenAI CLI import format or any unrecognized — always refresh.
  defp handle_device_oauth(cred, vendor, parsed) do
    do_refresh_and_persist(cred, vendor, parsed)
  end

  # Wrapped in a transaction with FOR UPDATE so concurrent fetches on an expired
  # credential don't both hit the refresh endpoint and race on the rotated token.
  defp do_refresh_and_persist(
         cred,
         vendor,
         _parsed,
         refresh_window_ms \\ 60_000,
         refresh_interval_ms \\ @default_oauth_refresh_interval_ms,
         force? \\ false
       ) do
    result =
      Repo.transaction(fn ->
        locked =
          Credential
          |> from(where: [name: ^cred.name], lock: "FOR UPDATE")
          |> Repo.one!()

        case do_refresh_inner(locked, vendor, refresh_window_ms, refresh_interval_ms, force?) do
          {:ok, access} -> access
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, access} -> {:ok, access}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_refresh_inner(locked, vendor, refresh_window_ms, refresh_interval_ms, force?) do
    with {:ok, blob} <- Encryption.decrypt(locked.encrypted_value),
         {:ok, locked_parsed} <- Jason.decode(blob) do
      now_ms = System.system_time(:millisecond)

      if force? or
           oauth_refresh_due?(
             vendor,
             locked_parsed,
             now_ms,
             refresh_window_ms,
             refresh_interval_ms
           ) do
        with refresh_token when is_binary(refresh_token) <-
               extract_refresh_token(vendor, locked_parsed) do
          refresh_and_persist_locked(locked, vendor, locked_parsed, refresh_token)
        else
          _ -> {:error, :missing_refresh_token}
        end
      else
        return_existing_token(locked.name, vendor, locked_parsed, refresh_interval_ms)
      end
    end
  end

  defp return_existing_token(
         name,
         :anthropic_oauth,
         %{"claudeAiOauth" => %{"accessToken" => access, "expiresAt" => expires_at_ms}},
         _refresh_interval_ms
       )
       when is_binary(access) and is_integer(expires_at_ms) do
    cache_and_return(name, access, expires_at_ms)
  end

  defp return_existing_token(
         name,
         :openai_oauth,
         %{"tokens" => %{"access_token" => access} = tokens} = parsed,
         refresh_interval_ms
       )
       when is_binary(access) do
    expires_at_ms =
      tokens["expires_at"] || inferred_refresh_expires_at(parsed, refresh_interval_ms)

    cache_and_return(name, access, expires_at_ms)
  end

  defp return_existing_token(
         name,
         _vendor,
         %{"access_token" => access, "expires_at" => expires_at_ms},
         _refresh_interval_ms
       )
       when is_binary(access) and is_integer(expires_at_ms) do
    cache_and_return(name, access, expires_at_ms)
  end

  defp return_existing_token(_name, _vendor, _parsed, _refresh_interval_ms) do
    {:error, :missing_access_token}
  end

  defp inferred_refresh_expires_at(parsed, refresh_interval_ms) do
    case parse_iso8601_ms(parsed["last_refresh"]) do
      {:ok, last_refresh_ms} -> last_refresh_ms + refresh_interval_ms
      :error -> System.system_time(:millisecond) + 60_000
    end
  end

  defp refresh_and_persist_locked(locked, vendor, parsed, refresh_token) do
    alias Backplane.Settings.OAuthRefresher

    with {:ok, refreshed} <- OAuthRefresher.refresh(vendor, refresh_token),
         updated = update_blob(vendor, parsed, refreshed),
         encoded = Jason.encode!(updated),
         encrypted = Encryption.encrypt(encoded),
         {:ok, updated_cred} <-
           locked
           |> Credential.changeset(%{encrypted_value: encrypted})
           |> Repo.update() do
      notify_changed({:ok, updated_cred})
      cache_and_return(locked.name, refreshed.access_token, refreshed.expires_at)
    end
  end

  # Anthropic CLI import format
  defp extract_refresh_token(:anthropic_oauth, %{"claudeAiOauth" => %{"refreshToken" => rt}}),
    do: rt

  # OpenAI CLI import format
  defp extract_refresh_token(:openai_oauth, %{"tokens" => %{"refresh_token" => rt}}), do: rt

  # Flat device-code format (anthropic, openai, or google stored via store_device_token)
  defp extract_refresh_token(_vendor, %{"refresh_token" => rt}), do: rt

  defp extract_refresh_token(_vendor, _parsed), do: nil

  # Anthropic CLI import format
  defp update_blob(:anthropic_oauth, %{"claudeAiOauth" => _} = parsed, refreshed) do
    parsed
    |> update_in(["claudeAiOauth"], fn oauth ->
      oauth
      |> Map.put("accessToken", refreshed.access_token)
      |> Map.put("refreshToken", refreshed.refresh_token)
      |> Map.put("expiresAt", refreshed.expires_at)
    end)
    |> Map.put("last_refresh", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  # OpenAI CLI import format
  defp update_blob(:openai_oauth, %{"tokens" => _} = parsed, refreshed) do
    updated_tokens =
      parsed["tokens"]
      |> Map.put("access_token", refreshed.access_token)
      |> Map.put("refresh_token", refreshed.refresh_token)
      |> Map.put("expires_at", refreshed.expires_at)
      |> then(fn t ->
        case Map.get(refreshed, :id_token) do
          nil -> t
          id_tok -> Map.put(t, "id_token", id_tok)
        end
      end)

    parsed
    |> Map.put("tokens", updated_tokens)
    |> Map.put("last_refresh", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  # Flat device-code format (google_oauth and any vendor stored via store_device_token)
  defp update_blob(_vendor, parsed, refreshed) do
    updated =
      parsed
      |> Map.put("access_token", refreshed.access_token)
      |> Map.put("refresh_token", refreshed.refresh_token)
      |> Map.put("expires_at", refreshed.expires_at)
      |> Map.put("last_refresh", DateTime.utc_now() |> DateTime.to_iso8601())

    case Map.get(refreshed, :id_token) do
      nil -> updated
      id_token -> Map.put(updated, "id_token", id_token)
    end
  end

  defp cache_and_return(name, access_token, expires_at_ms) do
    now_ms = System.system_time(:millisecond)
    expires_in_seconds = max(div(expires_at_ms - now_ms, 1000), 60)
    Backplane.Settings.TokenCache.put(name, access_token, expires_in_seconds)
    {:ok, access_token}
  end

  defp notify_changed({:ok, %Credential{} = cred}) do
    Vault.put(cred)
    Backplane.PubSubBroadcaster.broadcast_credential_changed(cred.name)
  end

  defp notify_changed(_), do: :ok
end
