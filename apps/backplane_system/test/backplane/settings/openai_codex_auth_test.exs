defmodule Backplane.Settings.OpenAICodexAuthTest do
  use BackplaneSystem.DataCase, async: false

  alias Backplane.Settings.{Credential, Credentials, Encryption, OpenAICodexAuth, TokenCache}

  setup do
    TokenCache.clear()

    {:ok, pid} = Bandit.start_link(plug: __MODULE__.MockEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    prior_codex = Application.get_env(:backplane, OpenAICodexAuth, [])
    prior_refresher = Application.get_env(:backplane, Backplane.Settings.OAuthRefresher, [])

    prior_env =
      snapshot_env(
        ~w[HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy]
      )

    Application.put_env(:backplane, OpenAICodexAuth,
      device_user_code_url: "http://localhost:#{port}/api/accounts/deviceauth/usercode",
      device_token_url: "http://localhost:#{port}/api/accounts/deviceauth/token",
      token_url: "http://localhost:#{port}/oauth/token",
      revoke_url: "http://localhost:#{port}/oauth/revoke"
    )

    Application.put_env(:backplane, Backplane.Settings.OAuthRefresher,
      openai_token_url: "http://localhost:#{port}/oauth/token"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OpenAICodexAuth, prior_codex)
      Application.put_env(:backplane, Backplane.Settings.OAuthRefresher, prior_refresher)
      restore_env(prior_env)

      try do
        ThousandIsland.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, mock_port: port}
  end

  defmodule MockEndpoint do
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)
    plug(:dispatch)

    post "/api/accounts/deviceauth/usercode" do
      if conn.body_params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann" do
        resp = %{
          "device_auth_id" => "mock-device-auth-id",
          "usercode" => "LNKB-13LTY",
          "interval" => "1"
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(resp))
      else
        send_resp(conn, 400, "bad client")
      end
    end

    post "/api/accounts/deviceauth/token" do
      case conn.body_params do
        %{"device_auth_id" => "pending-device-auth-id"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(403, Jason.encode!(%{"error" => "authorization_pending"}))

        %{"device_auth_id" => "mock-device-auth-id", "user_code" => "LNKB-13LTY"} ->
          resp = %{
            "authorization_code" => "mock-authorization-code",
            "code_challenge" => "mock-code-challenge",
            "code_verifier" => "mock-code-verifier"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        _ ->
          send_resp(conn, 400, "bad poll")
      end
    end

    post "/oauth/token" do
      case conn.body_params["grant_type"] do
        "authorization_code" ->
          resp = %{
            "id_token" =>
              jwt(%{
                "chatgpt_account_id" => "acc-123",
                "chatgpt_plan_type" => "plus",
                "email" => "codex@example.com",
                "organization_id" => "org-123",
                "project_id" => "proj-123",
                "exp" => 1_900_000_000
              }),
            "access_token" => "access-from-code",
            "refresh_token" => "refresh-from-code"
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        "refresh_token" ->
          resp = %{
            "id_token" =>
              jwt(%{
                "chatgpt_account_id" => "acc-456",
                "chatgpt_plan_type" => "team",
                "email" => "fresh@example.com",
                "exp" => 1_900_000_000
              }),
            "access_token" => "access-from-refresh",
            "refresh_token" => "refresh-from-refresh",
            "expires_in" => 3600
          }

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(resp))

        _ ->
          send_resp(conn, 400, "bad grant")
      end
    end

    post "/oauth/revoke" do
      if conn.body_params["token_type_hint"] == "refresh_token" do
        send_resp(conn, 200, "{}")
      else
        send_resp(conn, 400, "bad revoke")
      end
    end

    defp jwt(payload) do
      encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
      "header.#{encoded_payload}.sig"
    end
  end

  describe "start_device_login/0" do
    test "requests a Codex device code" do
      assert {:ok, login} = OpenAICodexAuth.start_device_login()

      assert login.device_auth_id == "mock-device-auth-id"
      assert login.user_code == "LNKB-13LTY"
      assert login.interval_seconds == 1
      assert login.verification_url == "https://auth.openai.com/codex/device"
      assert login.status == :pending
      assert login.expires_at > System.system_time(:millisecond)
    end

    test "uses HTTP_PROXY for device-code requests when the target is not in NO_PROXY", %{
      mock_port: port
    } do
      Application.put_env(:backplane, OpenAICodexAuth,
        device_user_code_url: "http://auth.openai.invalid/api/accounts/deviceauth/usercode"
      )

      System.put_env("HTTP_PROXY", "http://localhost:#{port}")
      System.delete_env("http_proxy")
      System.delete_env("HTTPS_PROXY")
      System.delete_env("https_proxy")
      System.delete_env("ALL_PROXY")
      System.delete_env("all_proxy")
      System.put_env("NO_PROXY", "localhost,127.0.0.1")
      System.put_env("no_proxy", "localhost,127.0.0.1")

      assert {:ok, login} = OpenAICodexAuth.start_device_login()
      assert login.device_auth_id == "mock-device-auth-id"
    end
  end

  describe "poll_device_login/1" do
    test "returns pending for an incomplete login" do
      login = %{
        device_auth_id: "pending-device-auth-id",
        user_code: "LNKB-13LTY",
        interval_seconds: 1,
        expires_at: System.system_time(:millisecond) + 60_000
      }

      assert {:pending, ^login} = OpenAICodexAuth.poll_device_login(login)
    end

    test "returns authorization-code exchange material when login completes" do
      login = %{
        device_auth_id: "mock-device-auth-id",
        user_code: "LNKB-13LTY",
        interval_seconds: 1,
        expires_at: System.system_time(:millisecond) + 60_000
      }

      assert {:ok,
              %{
                authorization_code: "mock-authorization-code",
                code_challenge: "mock-code-challenge",
                code_verifier: "mock-code-verifier"
              }} = OpenAICodexAuth.poll_device_login(login)
    end
  end

  describe "exchange_authorization_code/1" do
    test "exchanges the code, decodes metadata, and stores encrypted tokens" do
      code_result = %{
        authorization_code: "mock-authorization-code",
        code_challenge: "mock-code-challenge",
        code_verifier: "mock-code-verifier",
        credential_name: "codex-device"
      }

      assert {:ok,
              %{
                status: :authenticated,
                credential_name: "codex-device",
                account_id: "acc-123",
                plan_type: "plus",
                email: "codex@example.com"
              }} = OpenAICodexAuth.exchange_authorization_code(code_result)

      cred = Repo.get_by!(Credential, name: "codex-device")
      assert cred.metadata["auth_type"] == "openai_oauth"
      assert cred.metadata["auth_mode"] == "chatgpt"
      assert cred.metadata["account_id"] == "acc-123"
      assert cred.metadata["plan_type"] == "plus"

      assert {:ok, raw} = Encryption.decrypt(cred.encrypted_value)
      stored = Jason.decode!(raw)
      assert stored["type"] == "codex_device_oauth"
      assert stored["auth_mode"] == "chatgpt"
      assert stored["access_token"] == "access-from-code"
      assert stored["refresh_token"] == "refresh-from-code"
      assert stored["account_id"] == "acc-123"
      assert stored["expires_at"] == 1_900_000_000_000
      assert is_binary(stored["last_refresh"])

      assert {:ok, "access-from-code"} = Credentials.fetch("codex-device")
    end
  end

  describe "refresh_tokens/1" do
    test "refreshes rotating tokens and persists the new token set" do
      token_set = %{
        "credential_name" => "codex-refresh",
        "type" => "codex_device_oauth",
        "auth_mode" => "chatgpt",
        "id_token" => "old-id",
        "access_token" => "old-access",
        "refresh_token" => "old-refresh",
        "expires_at" => System.system_time(:millisecond) - 1000
      }

      assert {:ok,
              %{
                status: :authenticated,
                credential_name: "codex-refresh",
                account_id: "acc-456",
                plan_type: "team",
                email: "fresh@example.com"
              }} = OpenAICodexAuth.refresh_tokens(token_set)

      cred = Repo.get_by!(Credential, name: "codex-refresh")
      assert {:ok, raw} = Encryption.decrypt(cred.encrypted_value)
      stored = Jason.decode!(raw)
      assert stored["access_token"] == "access-from-refresh"
      assert stored["refresh_token"] == "refresh-from-refresh"
      assert stored["id_token"] != "old-id"
      assert is_binary(stored["last_refresh"])
    end
  end

  describe "read_token_state/0 and logout/0" do
    test "reads and logs out the default Codex credential" do
      expires_at = System.system_time(:millisecond) + 60 * 60 * 1000

      {:ok, _} =
        Credentials.store_device_token(
          "openai-codex",
          "openai_oauth",
          %{
            "type" => "codex_device_oauth",
            "auth_mode" => "chatgpt",
            "id_token" => "id",
            "access_token" => "access-live",
            "refresh_token" => "refresh-live",
            "expires_at" => expires_at,
            "account_id" => "acc-live",
            "plan_type" => "plus"
          },
          %{"account_id" => "acc-live", "plan_type" => "plus"}
        )

      assert {:ok,
              %{
                status: :authenticated,
                credential_name: "openai-codex",
                account_id: "acc-live",
                plan_type: "plus",
                expires_at: ^expires_at
              }} = OpenAICodexAuth.read_token_state()

      assert {:ok, %{status: :logged_out}} = OpenAICodexAuth.logout()
      assert {:error, :not_found} = Credentials.fetch("openai-codex")
    end
  end

  defp snapshot_env(names) do
    Map.new(names, &{&1, System.get_env(&1)})
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
