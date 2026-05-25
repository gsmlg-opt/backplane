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
  alias Backplane.Settings.Encryption

  import Ecto.Query

  @doc "Store (upsert) a credential. Encrypts the plaintext value."
  @spec store(String.t(), String.t(), String.t(), map()) ::
          {:ok, Credential.t()} | {:error, term()}
  def store(name, plaintext, kind, metadata \\ %{}) do
    with :ok <- validate_oauth_metadata(metadata) do
      encrypted = Encryption.encrypt(plaintext)

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
  `auth_type` in metadata. Extra hints (e.g. `client_id` for Google AI) are
  stored unencrypted in metadata.
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
    case Repo.get_by(Credential, name: name) do
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
          {:ok, String.t(), %{auth_type: String.t(), extra_headers: [{String.t(), String.t()}]}}
          | {:error, term()}
  def fetch_with_meta(name) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      %Credential{metadata: meta} ->
        auth_type = (meta || %{}) |> Map.get("auth_type", "api_key")

        with {:ok, token} <- fetch(name) do
          {:ok, token, %{auth_type: auth_type, extra_headers: extra_headers_for(auth_type)}}
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
            :ok

          {:error, _} ->
            {:error, :delete_failed}
        end
    end
  end

  @doc "List all credentials. Never returns plaintext values."
  @spec list() :: [map()]
  def list do
    Credential
    |> select([c], %{
      id: c.id,
      name: c.name,
      kind: c.kind,
      metadata: c.metadata,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    })
    |> order_by([c], c.name)
    |> Repo.all()
  end

  @doc "Check if a credential exists by name."
  @spec exists?(String.t()) :: boolean()
  def exists?(name) do
    Credential
    |> where([c], c.name == ^name)
    |> Repo.exists?()
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
        end

        result
    end
  end

  @doc "Invalidate a cached OAuth2 token for the given credential."
  @spec invalidate_token(String.t()) :: :ok
  def invalidate_token(name), do: Backplane.Settings.TokenCache.invalidate(name)

  @doc "Update a credential's kind and/or metadata (not the secret)."
  @spec update(String.t(), map()) :: {:ok, Credential.t()} | {:error, :not_found | term()}
  def update(name, attrs) do
    case Repo.get_by(Credential, name: name) do
      nil ->
        {:error, :not_found}

      existing ->
        existing
        |> Credential.changeset(Map.take(attrs, [:kind, :metadata, "kind", "metadata"]))
        |> Repo.update()
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

  defp extra_headers_for("anthropic_oauth"), do: [{"anthropic-beta", "oauth-2025-04-20"}]
  defp extra_headers_for(_), do: []

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

  defp validate_oauth_metadata(%{"auth_type" => "anthropic_oauth"}), do: :ok
  defp validate_oauth_metadata(%{"auth_type" => "openai_oauth"}), do: :ok
  defp validate_oauth_metadata(%{"auth_type" => "google_oauth"}), do: :ok

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
  defp do_refresh_and_persist(cred, vendor, _parsed) do
    result =
      Repo.transaction(fn ->
        locked =
          Credential
          |> from(where: [name: ^cred.name], lock: "FOR UPDATE")
          |> Repo.one!()

        case do_refresh_inner(locked, vendor) do
          {:ok, access} -> access
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, access} -> {:ok, access}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_refresh_inner(locked, vendor) do
    with {:ok, blob} <- Encryption.decrypt(locked.encrypted_value),
         {:ok, locked_parsed} <- Jason.decode(blob) do
      case maybe_short_circuit(vendor, locked_parsed) do
        {:ok, fresh_access, fresh_expires_ms} ->
          cache_and_return(locked.name, fresh_access, fresh_expires_ms)

        :stale ->
          refresh_token = extract_refresh_token(vendor, locked_parsed)
          refresh_and_persist_locked(locked, vendor, locked_parsed, refresh_token)
      end
    end
  end

  # Re-check freshness inside the lock; if another waiter already refreshed, short-circuit.
  defp maybe_short_circuit(
         :anthropic_oauth,
         %{"claudeAiOauth" => %{"accessToken" => access, "expiresAt" => expires_at_ms}}
       )
       when is_binary(access) and is_integer(expires_at_ms) do
    if expires_at_ms > System.system_time(:millisecond) + 60_000 do
      {:ok, access, expires_at_ms}
    else
      :stale
    end
  end

  # Flat device-code format — check expires_at for any vendor.
  defp maybe_short_circuit(
         _vendor,
         %{"access_token" => access, "expires_at" => expires_at_ms}
       )
       when is_binary(access) and is_integer(expires_at_ms) do
    if expires_at_ms > System.system_time(:millisecond) + 60_000 do
      {:ok, access, expires_at_ms}
    else
      :stale
    end
  end

  defp maybe_short_circuit(_vendor, _parsed), do: :stale

  # Google OAuth: pass client_id from metadata when refreshing.
  defp refresh_and_persist_locked(locked, :google_oauth, parsed, refresh_token) do
    alias Backplane.Settings.OAuthRefresher

    client_id = get_in(locked.metadata, ["client_id"]) || ""

    with {:ok, refreshed} <-
           OAuthRefresher.refresh(:google_oauth, refresh_token, client_id: client_id),
         updated = update_blob(:google_oauth, parsed, refreshed),
         encoded = Jason.encode!(updated),
         encrypted = Encryption.encrypt(encoded),
         {:ok, _} <-
           locked
           |> Credential.changeset(%{encrypted_value: encrypted})
           |> Repo.update() do
      cache_and_return(locked.name, refreshed.access_token, refreshed.expires_at)
    end
  end

  defp refresh_and_persist_locked(locked, vendor, parsed, refresh_token) do
    alias Backplane.Settings.OAuthRefresher

    with {:ok, refreshed} <- OAuthRefresher.refresh(vendor, refresh_token),
         updated = update_blob(vendor, parsed, refreshed),
         encoded = Jason.encode!(updated),
         encrypted = Encryption.encrypt(encoded),
         {:ok, _} <-
           locked
           |> Credential.changeset(%{encrypted_value: encrypted})
           |> Repo.update() do
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

  # Anthropic CLI import format
  defp update_blob(:anthropic_oauth, %{"claudeAiOauth" => _} = parsed, refreshed) do
    update_in(parsed, ["claudeAiOauth"], fn oauth ->
      oauth
      |> Map.put("accessToken", refreshed.access_token)
      |> Map.put("refreshToken", refreshed.refresh_token)
      |> Map.put("expiresAt", refreshed.expires_at)
    end)
  end

  # OpenAI CLI import format
  defp update_blob(:openai_oauth, %{"tokens" => _} = parsed, refreshed) do
    updated_tokens =
      parsed["tokens"]
      |> Map.put("access_token", refreshed.access_token)
      |> Map.put("refresh_token", refreshed.refresh_token)
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
    parsed
    |> Map.put("access_token", refreshed.access_token)
    |> Map.put("refresh_token", refreshed.refresh_token)
    |> Map.put("expires_at", refreshed.expires_at)
  end

  defp cache_and_return(name, access_token, expires_at_ms) do
    now_ms = System.system_time(:millisecond)
    expires_in_seconds = max(div(expires_at_ms - now_ms, 1000), 60)
    Backplane.Settings.TokenCache.put(name, access_token, expires_in_seconds)
    {:ok, access_token}
  end
end
