defmodule Backplane.LLM.ResponsesWebSocket.Headers do
  @moduledoc false
  alias Backplane.LLM.{CredentialPlug, HeaderPolicy}
  alias Backplane.Settings.{Credentials, Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault
  alias Backplane.Repo

  @client ~w(session_id conversation_id x-codex-turn-state x-codex-turn-metadata openai-beta originator user-agent x-client-request-id)

  def build(conn, route) do
    with {:ok, token, meta, snapshot} <- credential(route.provider.credential) do
      nominated = HeaderPolicy.connection_nominated(conn.req_headers)

      client =
        conn.req_headers
        |> Enum.map(fn {k, v} -> {String.downcase(k), v} end)
        |> Enum.filter(fn {k, _} -> k in @client and k not in nominated end)

      defaults =
        HeaderPolicy.merge_defaults(
          route.provider.default_headers,
          route.api.default_headers,
          surface: :responses_websocket
        )

      {owned, fallback} =
        if meta.auth_type == "openai_oauth" do
          {owned, codex_defaults} = CredentialPlug.codex_headers(token, meta)
          {owned, codex_defaults}
        else
          {[{"authorization", "Bearer " <> token}], []}
        end

      # Provider/API defaults win over caller metadata, and credential-owned values win last.
      headers = HeaderPolicy.merge_ordered([fallback, client, defaults, owned])

      {:ok, headers, snapshot}
    end
  end

  defp credential(name) do
    # API keys use a verified database snapshot, not an independently stale cache.
    case Repo.get_by(Credential, name: name) do
      %Credential{metadata: metadata} = record ->
        case Map.get(metadata || %{}, "auth_type", "api_key") do
          type when type in [nil, "api_key"] ->
            with {:ok, token} <- Encryption.decrypt(record.encrypted_value),
                 do: {:ok, token, %{auth_type: type, metadata: metadata || %{}}, record}

          "openai_oauth" ->
            if Vault.get(name) == record do
              oauth_credential(record)
            else
              {:error, :credential_unavailable}
            end

          _ ->
            {:error, :unsupported_credential}
        end

      _ ->
        {:error, :credential_unavailable}
    end
  end

  defp oauth_credential(record) do
    # Refresh happens only before upstream connection creation. Re-read the persisted
    # snapshot, then verify it did not change while retrieving the refreshed token.
    with {:ok, _, _} <- Credentials.fetch_with_meta(record.name),
         %Credential{} = refreshed <- Repo.get(Credential, record.id),
         true <- Vault.get(record.name) == refreshed,
         {:ok, token, meta} <- Credentials.fetch_with_meta(record.name),
         true <- Repo.get(Credential, record.id) == refreshed,
         true <- token_matches?(refreshed, token) do
      {:ok, token, meta, refreshed}
    else
      _ -> {:error, :credential_unavailable}
    end
  end

  defp token_matches?(snapshot, token) do
    with {:ok, blob} <- Encryption.decrypt(snapshot.encrypted_value),
         {:ok, parsed} <- Formata.JSON.decode(blob) do
      case parsed do
        %{"access_token" => ^token} -> true
        %{"tokens" => %{"access_token" => ^token}} -> true
        _ -> false
      end
    else
      _ -> false
    end
  end
end
