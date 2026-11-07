defmodule Backplane.LLM.ResponsesWebSocket.Headers do
  @moduledoc false
  alias Backplane.LLM.CredentialPlug
  alias Backplane.Settings.{Credentials, Credential, Encryption}
  alias Backplane.Settings.Credentials.Vault
  alias Backplane.Repo

  @client ~w(session_id conversation_id x-codex-turn-state x-codex-turn-metadata openai-beta originator user-agent x-client-request-id)
  @forbidden ~w(authorization x-api-key api-key x-goog-api-key proxy-authorization cookie set-cookie host connection upgrade content-length transfer-encoding keep-alive te trailer sec-websocket-key sec-websocket-accept sec-websocket-version sec-websocket-protocol sec-websocket-extensions chatgpt-account-id x-openai-fedramp)

  def build(conn, route) do
    with {:ok, token, meta, snapshot} <- credential(route.provider.credential) do
      nominated =
        conn
        |> Plug.Conn.get_req_header("connection")
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.downcase(String.trim(&1)))

      client = Enum.filter(conn.req_headers, fn {k, _} -> k in @client and k not in nominated end)

      defaults =
        Map.merge(normalize(route.provider.default_headers), normalize(route.api.default_headers))

      defaults = Enum.reject(defaults, fn {k, _} -> k in @forbidden end)

      {owned, fallback} =
        if meta.auth_type == "openai_oauth" do
          {owned, codex_defaults} = CredentialPlug.codex_headers(token, meta)
          {owned, codex_defaults}
        else
          {[{"authorization", "Bearer " <> token}], []}
        end

      # Provider defaults win over caller metadata, and credential-owned values win last.
      headers =
        fallback
        |> merge(client)
        |> merge(defaults)
        |> merge(owned)
        |> Enum.reject(fn {_, v} -> is_nil(v) end)

      {:ok, headers, snapshot}
    end
  end

  defp normalize(headers) do
    Map.new(headers || %{}, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp merge(headers, replacements) do
    names = MapSet.new(replacements, &elem(&1, 0))
    Enum.reject(headers, fn {name, _} -> MapSet.member?(names, name) end) ++ replacements
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
         {:ok, parsed} <- Jason.decode(blob) do
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
