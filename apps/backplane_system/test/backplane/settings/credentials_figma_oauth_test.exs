defmodule Backplane.Settings.CredentialsFigmaOAuthTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Repo

  alias Backplane.Settings.{
    Credential,
    Credentials,
    Encryption,
    OAuthRefresher,
    OAuthTokenRefreshWorker,
    TokenCache
  }

  setup do
    TokenCache.clear()
    {:ok, pid} = Bandit.start_link(plug: __MODULE__.RefreshEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = Application.get_env(:backplane, OAuthRefresher, [])

    Application.put_env(
      :backplane,
      OAuthRefresher,
      Keyword.merge(previous,
        figma_token_url: "http://localhost:#{port}/figma/token",
        figma_mcp_client_id: "test-figma-client",
        figma_mcp_client_secret: "test-figma-secret"
      )
    )

    on_exit(fn ->
      TokenCache.clear()
      Application.put_env(:backplane, OAuthRefresher, previous)

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
    plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
    plug(:dispatch)

    post "/figma/token" do
      expected_auth = "Basic " <> Base.encode64("test-figma-client:test-figma-secret")

      valid? =
        conn.body_params["grant_type"] == "refresh_token" and
          conn.body_params["resource"] == "https://mcp.figma.com/mcp" and
          get_req_header(conn, "authorization") == [expected_auth]

      cond do
        valid? and conn.body_params["refresh_token"] == "good-figma" ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "access_token" => "figma-refreshed-access",
              "refresh_token" => "figma-refreshed-refresh",
              "expires_in" => 3600
            })
          )

        true ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{"error" => "invalid_grant"}))
      end
    end
  end

  test "stores a Figma token as an encrypted upstream OAuth credential" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, credential} =
             Credentials.store_oauth_token(
               "figma-mcp",
               "figma_oauth",
               %{
                 "access_token" => "figma-access",
                 "refresh_token" => "figma-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert credential.kind == "upstream"
    assert credential.metadata == %{"auth_type" => "figma_oauth"}
    refute Map.has_key?(credential.metadata, "client_id")
    refute Map.has_key?(credential.metadata, "client_secret")

    assert {:ok, plaintext} = Encryption.decrypt(credential.encrypted_value)

    assert %{
             "access_token" => "figma-access",
             "refresh_token" => "figma-refresh",
             "expires_at" => ^expires_at
           } = Jason.decode!(plaintext)

    assert {:ok, "figma-access"} = Credentials.fetch("figma-mcp")
  end

  test "reauthorizing the same name invalidates the cached access token" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-reconnect",
               "figma_oauth",
               %{
                 "access_token" => "old-access",
                 "refresh_token" => "old-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert {:ok, "old-access"} = Credentials.fetch("figma-reconnect")
    assert {:ok, "old-access"} = TokenCache.get("figma-reconnect")

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-reconnect",
               "figma_oauth",
               %{
                 "access_token" => "new-access",
                 "refresh_token" => "new-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert :miss = TokenCache.get("figma-reconnect")
    assert {:ok, "new-access"} = Credentials.fetch("figma-reconnect")

    stored = Repo.get_by!(Credential, name: "figma-reconnect")
    assert stored.kind == "upstream"
  end

  test "existing device OAuth storage keeps the llm kind" do
    assert {:ok, credential} =
             Credentials.store_device_token(
               "legacy-google",
               "google_oauth",
               %{
                 "access_token" => "google-access",
                 "refresh_token" => "google-refresh",
                 "expires_at" => System.system_time(:millisecond) + 3_600_000
               },
               %{}
             )

    assert credential.kind == "llm"
    assert credential.metadata["auth_type"] == "google_oauth"
  end

  test "fetch refreshes and persists an expired Figma token" do
    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-expired",
               "figma_oauth",
               %{
                 "access_token" => "figma-old-access",
                 "refresh_token" => "good-figma",
                 "expires_at" => System.system_time(:millisecond) - 60_000
               },
               "upstream",
               %{}
             )

    assert {:ok, "figma-refreshed-access"} = Credentials.fetch("figma-expired")

    stored = decrypt_credential_json("figma-expired")
    assert stored["access_token"] == "figma-refreshed-access"
    assert stored["refresh_token"] == "figma-refreshed-refresh"
    assert is_binary(stored["last_refresh"])
  end

  test "failed refresh preserves the encrypted token blob" do
    old = %{
      "access_token" => "figma-old-access",
      "refresh_token" => "rejected-figma",
      "expires_at" => System.system_time(:millisecond) - 60_000
    }

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-refresh-failure",
               "figma_oauth",
               old,
               "upstream",
               %{}
             )

    assert {:error, {:refresh_failed, 401}} = Credentials.fetch("figma-refresh-failure")
    assert decrypt_credential_json("figma-refresh-failure") == old
  end

  test "caps the Figma proactive refresh window at ten minutes" do
    now_ms = System.system_time(:millisecond)

    for {name, minutes} <- [{"figma-nine", 9}, {"figma-eleven", 11}] do
      assert {:ok, _} =
               Credentials.store_oauth_token(
                 name,
                 "figma_oauth",
                 %{
                   "access_token" => name <> "-access",
                   "refresh_token" => "good-figma",
                   "expires_at" => now_ms + minutes * 60_000
                 },
                 "upstream",
                 %{}
               )
    end

    assert ["figma-nine"] =
             Credentials.oauth_credentials_due_for_refresh(
               auth_types: ["figma_oauth"],
               now_ms: now_ms,
               refresh_window_ms: 2 * 60 * 60 * 1000
             )

    assert {:ok, :fresh} =
             Credentials.refresh_oauth_token(
               "figma-eleven",
               now_ms: now_ms,
               refresh_window_ms: 2 * 60 * 60 * 1000
             )
  end

  test "default worker scan refreshes only due Figma credentials" do
    now_ms = System.system_time(:millisecond)

    for {name, minutes} <- [{"figma-worker-due", 9}, {"figma-worker-fresh", 11}] do
      assert {:ok, _} =
               Credentials.store_oauth_token(
                 name,
                 "figma_oauth",
                 %{
                   "access_token" => name <> "-old",
                   "refresh_token" => "good-figma",
                   "expires_at" => now_ms + minutes * 60_000
                 },
                 "upstream",
                 %{}
               )
    end

    assert :ok = OAuthTokenRefreshWorker.perform(%Oban.Job{args: %{}})

    assert decrypt_credential_json("figma-worker-due")["access_token"] ==
             "figma-refreshed-access"

    assert decrypt_credential_json("figma-worker-fresh")["access_token"] ==
             "figma-worker-fresh-old"
  end

  test "OAuth status exposes lifecycle state without secrets" do
    expires_at = System.system_time(:millisecond) + 3_600_000

    assert {:ok, _} =
             Credentials.store_oauth_token(
               "figma-status",
               "figma_oauth",
               %{
                 "access_token" => "figma-status-access",
                 "refresh_token" => "figma-status-refresh",
                 "expires_at" => expires_at
               },
               "upstream",
               %{}
             )

    assert {:ok, status} = Credentials.oauth_status("figma-status")
    assert status.auth_type == "figma_oauth"
    assert status.status == :active
    assert status.expires_at_ms == expires_at
    refute Map.has_key?(status, :access_token)
    refute Map.has_key?(status, :refresh_token)
  end

  defp decrypt_credential_json(name) do
    credential = Repo.get_by!(Credential, name: name)
    {:ok, plaintext} = Encryption.decrypt(credential.encrypted_value)
    Jason.decode!(plaintext)
  end
end
