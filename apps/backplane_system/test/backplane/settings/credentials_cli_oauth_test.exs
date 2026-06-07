defmodule Backplane.Settings.CredentialsCliOAuthTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Settings.{
    Credentials,
    Encryption,
    OAuthRefresher,
    OAuthTokenRefreshWorker,
    TokenCache
  }

  @anthropic_json ~s({"claudeAiOauth":{"accessToken":"sk-ant-oat01-aaaa","refreshToken":"sk-ant-ort01-bbbb","expiresAt":1776417713649,"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"organizationUuid":"org-uuid-1234"})

  @openai_json ~s({"OPENAI_API_KEY":null,"tokens":{"id_token":"id-aaa","access_token":"oai-bbb","refresh_token":"oai-ccc","account_id":"acc-1"},"last_refresh":"2026-04-15T12:34:56Z"})

  setup do
    TokenCache.clear()

    {:ok, pid} = Bandit.start_link(plug: __MODULE__.RefreshEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    prior = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(:backplane, OAuthRefresher,
      anthropic_token_url: "http://localhost:#{port}/anthropic/token",
      openai_token_url: "http://localhost:#{port}/openai/token"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defmodule RefreshEndpoint do
    use Plug.Router
    plug(:match)
    plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason)
    plug(:dispatch)

    post "/anthropic/token" do
      unless valid_anthropic_headers?(conn) do
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{"error" => "missing_claude_code_headers"}))
      else
        resp = %{
          "access_token" => "sk-ant-oat01-REFRESHED",
          "refresh_token" => "sk-ant-ort01-NEWREFRESH",
          "expires_in" => 28_800,
          "token_type" => "Bearer"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(resp))
      end
    end

    defp valid_anthropic_headers?(conn) do
      headers = Map.new(conn.req_headers)

      headers["user-agent"] == "claude-cli/2.1.165 (external, cli)" and
        headers["x-app"] == "cli" and
        headers["anthropic-client-platform"] == "claude_code_cli"
    end

    post "/openai/token" do
      resp = %{
        "access_token" => "oai-REFRESHED",
        "refresh_token" => "oai-NEWREFRESH",
        "id_token" => "oai-NEWID",
        "expires_in" => 3600,
        "token_type" => "Bearer"
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(resp))
    end

    match _ do
      send_resp(conn, 404, "not found")
    end
  end

  describe "import_cli_auth/2 — Anthropic" do
    test "stores credential with auth_type=anthropic_oauth and raw JSON encrypted" do
      assert {:ok, cred} = Credentials.import_cli_auth("claude-code-oauth", @anthropic_json)
      assert cred.metadata["auth_type"] == "anthropic_oauth"
      assert cred.metadata["subscription_type"] == "max"
      assert cred.metadata["organization_uuid"] == "org-uuid-1234"

      assert {:ok, plaintext} = Encryption.decrypt(cred.encrypted_value)
      assert plaintext == @anthropic_json
    end
  end

  describe "import_cli_auth/2 — OpenAI" do
    test "stores credential with auth_type=openai_oauth and raw JSON encrypted" do
      assert {:ok, cred} = Credentials.import_cli_auth("codex-oauth", @openai_json)
      assert cred.metadata["auth_type"] == "openai_oauth"
      assert cred.metadata["account_id"] == "acc-1"

      assert {:ok, plaintext} = Encryption.decrypt(cred.encrypted_value)
      assert plaintext == @openai_json
    end
  end

  describe "import_cli_auth/2 — errors" do
    test "rejects malformed JSON" do
      assert {:error, :invalid_json} = Credentials.import_cli_auth("bad", "not json {")
    end

    test "rejects unrecognized JSON shape" do
      assert {:error, :unrecognized_format} =
               Credentials.import_cli_auth("bad", ~s({"foo":"bar"}))
    end
  end

  describe "fetch/1 with anthropic_oauth credential" do
    test "returns the access_token when expiresAt is in the future" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-LIVE",
            "refreshToken" => "sk-ant-ort01-rrr",
            "expiresAt" => future_ms,
            "scopes" => [],
            "subscriptionType" => "max"
          },
          "organizationUuid" => "org-1"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-live", json)

      assert {:ok, "sk-ant-oat01-LIVE"} = Credentials.fetch("ant-live")
    end

    test "refreshes and persists rotated blob when expired" do
      past_ms = System.system_time(:millisecond) - 60_000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-EXPIRED",
            "refreshToken" => "sk-ant-ort01-rrr",
            "expiresAt" => past_ms,
            "scopes" => [],
            "subscriptionType" => "max"
          },
          "organizationUuid" => "org-1"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-expired", json)

      assert {:ok, "sk-ant-oat01-REFRESHED"} = Credentials.fetch("ant-expired")

      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "ant-expired")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["claudeAiOauth"]["accessToken"] == "sk-ant-oat01-REFRESHED"
      assert parsed["claudeAiOauth"]["refreshToken"] == "sk-ant-ort01-NEWREFRESH"
      assert parsed["claudeAiOauth"]["expiresAt"] > System.system_time(:millisecond)
    end
  end

  describe "fetch/1 with openai_oauth credential" do
    test "always refreshes (no expiresAt in file) and returns new access_token" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "id-old",
            "access_token" => "oai-OLD",
            "refresh_token" => "oai-rrr",
            "account_id" => "acc-1"
          },
          "last_refresh" => "2026-04-15T12:34:56Z"
        })

      {:ok, _} = Credentials.import_cli_auth("oai-cred", json)

      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-cred")

      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "oai-cred")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["tokens"]["access_token"] == "oai-REFRESHED"
      assert parsed["tokens"]["refresh_token"] == "oai-NEWREFRESH"
      assert parsed["tokens"]["id_token"] == "oai-NEWID"
    end

    test "second fetch within TTL hits cache, does not re-refresh" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "id-old",
            "access_token" => "oai-OLD",
            "refresh_token" => "oai-rrr",
            "account_id" => "acc-1"
          }
        })

      {:ok, _} = Credentials.import_cli_auth("oai-cache", json)

      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-cache")
      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-cache")

      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "oai-cache")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["tokens"]["refresh_token"] == "oai-NEWREFRESH"
    end

    test "refreshes flat Codex device token blobs and persists the rotated id_token" do
      past_ms = System.system_time(:millisecond) - 60_000

      {:ok, _} =
        Credentials.store_device_token(
          "oai-flat-expired",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "auth_mode" => "chatgpt",
            "id_token" => "oai-OLDID",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "expires_at" => past_ms
          },
          %{"auth_mode" => "chatgpt"}
        )

      assert {:ok, "oai-REFRESHED"} = Credentials.fetch("oai-flat-expired")

      cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: "oai-flat-expired")
      {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
      parsed = Jason.decode!(blob)
      assert parsed["access_token"] == "oai-REFRESHED"
      assert parsed["refresh_token"] == "oai-NEWREFRESH"
      assert parsed["id_token"] == "oai-NEWID"
      assert is_binary(parsed["last_refresh"])
    end
  end

  describe "automatic OAuth refresh" do
    test "lists flat Codex credentials due after the refresh interval" do
      now_ms = System.system_time(:millisecond)

      {:ok, _} =
        Credentials.store_device_token(
          "oai-auto-due",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "access_token" => "oai-DUE",
            "refresh_token" => "rt-due",
            "expires_at" => now_ms + 10 * 24 * 60 * 60 * 1000,
            "last_refresh" => iso_days_ago(8)
          }
        )

      {:ok, _} =
        Credentials.store_device_token(
          "oai-auto-fresh",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "access_token" => "oai-FRESH",
            "refresh_token" => "rt-fresh",
            "expires_at" => now_ms + 10 * 24 * 60 * 60 * 1000,
            "last_refresh" => iso_days_ago(6)
          }
        )

      {:ok, _} = Credentials.store("plain-auto", "sk-plain", "llm")

      assert ["oai-auto-due"] =
               Credentials.oauth_credentials_due_for_refresh(
                 auth_types: ["openai_oauth"],
                 now_ms: now_ms,
                 refresh_interval_ms: 7 * 24 * 60 * 60 * 1000
               )
               |> Enum.sort()
    end

    test "refresh_oauth_token/2 refreshes a Codex token after the refresh interval" do
      now_ms = System.system_time(:millisecond)

      {:ok, _} =
        Credentials.store_device_token(
          "oai-auto-refresh",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "id_token" => "oai-OLDID",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "expires_at" => now_ms + 10 * 24 * 60 * 60 * 1000,
            "last_refresh" => iso_days_ago(8)
          }
        )

      assert {:ok, :refreshed} =
               Credentials.refresh_oauth_token("oai-auto-refresh",
                 now_ms: now_ms,
                 refresh_interval_ms: 7 * 24 * 60 * 60 * 1000
               )

      stored = decrypt_credential_json("oai-auto-refresh")
      assert stored["access_token"] == "oai-REFRESHED"
      assert stored["refresh_token"] == "oai-NEWREFRESH"
      assert stored["id_token"] == "oai-NEWID"
      assert is_binary(stored["last_refresh"])
    end

    test "refresh_oauth_token/2 skips a Codex token before the refresh interval" do
      now_ms = System.system_time(:millisecond)

      {:ok, _} =
        Credentials.store_device_token(
          "oai-auto-skip",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "access_token" => "oai-FRESH",
            "refresh_token" => "rt",
            "expires_at" => now_ms + 10 * 24 * 60 * 60 * 1000,
            "last_refresh" => iso_days_ago(6)
          }
        )

      assert {:ok, :fresh} =
               Credentials.refresh_oauth_token("oai-auto-skip",
                 now_ms: now_ms,
                 refresh_interval_ms: 7 * 24 * 60 * 60 * 1000
               )

      stored = decrypt_credential_json("oai-auto-skip")
      assert stored["access_token"] == "oai-FRESH"
    end

    test "OAuthTokenRefreshWorker refreshes a named Codex credential" do
      now_ms = System.system_time(:millisecond)

      {:ok, _} =
        Credentials.store_device_token(
          "oai-worker-refresh",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "expires_at" => now_ms + 10 * 24 * 60 * 60 * 1000,
            "last_refresh" => iso_days_ago(8)
          }
        )

      assert :ok =
               OAuthTokenRefreshWorker.perform(%Oban.Job{
                 args: %{
                   "credential_name" => "oai-worker-refresh",
                   "refresh_interval_ms" => 7 * 24 * 60 * 60 * 1000
                 }
               })

      stored = decrypt_credential_json("oai-worker-refresh")
      assert stored["access_token"] == "oai-REFRESHED"
    end
  end

  describe "fetch_with_meta/1" do
    test "returns api_key auth_type for plain credentials" do
      {:ok, _} = Credentials.store("plain", "sk-1234abcd", "llm")

      assert {:ok, "sk-1234abcd", %{auth_type: "api_key", extra_headers: []}} =
               Credentials.fetch_with_meta("plain")
    end

    test "returns anthropic_oauth auth_type with anthropic-beta extra header" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-LIVE",
            "refreshToken" => "rt",
            "expiresAt" => future_ms,
            "scopes" => []
          },
          "organizationUuid" => "org-1"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-meta", json)

      assert {:ok, "sk-ant-oat01-LIVE",
              %{
                auth_type: "anthropic_oauth",
                extra_headers: [{"anthropic-beta", "oauth-2025-04-20"}]
              }} =
               Credentials.fetch_with_meta("ant-meta")
    end

    test "returns openai_oauth auth_type with Codex backend headers" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "i",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "account_id" => "a"
          }
        })

      {:ok, _} = Credentials.import_cli_auth("oai-meta", json)

      assert {:ok, "oai-REFRESHED",
              %{
                auth_type: "openai_oauth",
                extra_headers: extra_headers,
                metadata: %{"account_id" => "a"}
              }} =
               Credentials.fetch_with_meta("oai-meta")

      refute {"authorization", "Bearer oai-REFRESHED"} in extra_headers
      assert {"chatgpt-account-id", "a"} in extra_headers
      assert {"originator", "codex_cli_rs"} in extra_headers
    end

    test "returns {:error, :not_found} for unknown name" do
      assert {:error, :not_found} = Credentials.fetch_with_meta("nope")
    end
  end

  describe "fetch_hint/1 for OAuth credentials" do
    test "returns last 4 of accessToken for anthropic_oauth" do
      future_ms = System.system_time(:millisecond) + 60 * 60 * 1000

      json =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => "sk-ant-oat01-XYZW1234",
            "refreshToken" => "rt",
            "expiresAt" => future_ms,
            "scopes" => []
          },
          "organizationUuid" => "o"
        })

      {:ok, _} = Credentials.import_cli_auth("ant-hint", json)

      assert "...1234" = Credentials.fetch_hint("ant-hint")
    end

    test "returns last 4 of access_token for openai_oauth (after refresh)" do
      json =
        Jason.encode!(%{
          "OPENAI_API_KEY" => nil,
          "tokens" => %{
            "id_token" => "i",
            "access_token" => "oai-OLD",
            "refresh_token" => "rt",
            "account_id" => "a"
          }
        })

      {:ok, _} = Credentials.import_cli_auth("oai-hint", json)

      # fetch_hint triggers a refresh; last 4 of "oai-REFRESHED" is "SHED"
      assert "...SHED" = Credentials.fetch_hint("oai-hint")
    end
  end

  defp decrypt_credential_json(name) do
    cred = Backplane.Repo.get_by!(Backplane.Settings.Credential, name: name)
    {:ok, blob} = Backplane.Settings.Encryption.decrypt(cred.encrypted_value)
    Jason.decode!(blob)
  end

  defp iso_days_ago(days) do
    DateTime.utc_now()
    |> DateTime.add(-days * 86_400, :second)
    |> DateTime.to_iso8601()
  end
end
