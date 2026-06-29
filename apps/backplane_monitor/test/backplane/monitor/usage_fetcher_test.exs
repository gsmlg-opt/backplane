defmodule Backplane.Monitor.UsageFetcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.Providers.{ClaudeCode, GoogleAntigravity, OpenAICodex}
  alias Backplane.Monitor.UsageFetcher
  alias Backplane.Settings.Credential
  alias Backplane.Settings.Credentials
  alias Backplane.Settings.Credentials.Vault
  alias Backplane.Settings.OAuthRefresher

  defmodule OpenAIRefreshEndpoint do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/openai/token" do
      resp = %{
        "access_token" => "new-access",
        "refresh_token" => "new-refresh",
        "id_token" => jwt(%{"profile" => %{"chatgpt_account_id" => "acc-refreshed"}}),
        "expires_in" => 3600,
        "token_type" => "Bearer"
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(resp))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "not found")
    end

    defp jwt(payload) do
      encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
      "header.#{encoded_payload}.sig"
    end
  end

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    Ecto.Adapters.SQL.Sandbox.allow(Backplane.Repo, self(), Backplane.Settings.Credentials.Vault)

    previous_openai = Application.get_env(:backplane, :openai_codex_monitor_req_options)
    previous_claude = Application.get_env(:backplane, :claude_code_monitor_req_options)
    previous_google = Application.get_env(:backplane, :google_antigravity_monitor_req_options)

    Application.put_env(:backplane, :openai_codex_monitor_req_options,
      plug: {Req.Test, OpenAICodex}
    )

    Application.put_env(:backplane, :claude_code_monitor_req_options,
      plug: {Req.Test, ClaudeCode}
    )

    Application.put_env(:backplane, :google_antigravity_monitor_req_options,
      plug: {Req.Test, GoogleAntigravity}
    )

    on_exit(fn ->
      if previous_openai do
        Application.put_env(:backplane, :openai_codex_monitor_req_options, previous_openai)
      else
        Application.delete_env(:backplane, :openai_codex_monitor_req_options)
      end

      if previous_claude do
        Application.put_env(:backplane, :claude_code_monitor_req_options, previous_claude)
      else
        Application.delete_env(:backplane, :claude_code_monitor_req_options)
      end

      if previous_google do
        Application.put_env(:backplane, :google_antigravity_monitor_req_options, previous_google)
      else
        Application.delete_env(:backplane, :google_antigravity_monitor_req_options)
      end
    end)

    :ok
  end

  test "fetch_usage/1 rejects Claude Code script credentials" do
    credential_name = unique_name("claude-script")

    {:ok, _credential} =
      Credentials.store(credential_name, "fetch('https://example.com')", "script")

    plan = %Plan{
      provider: "claude_code",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:error, {:invalid_credential_kind, "script", "anthropic_oauth"}} =
             UsageFetcher.fetch_usage(plan)
  end

  test "fetch_usage/1 fetches Claude Code usage with Anthropic OAuth credentials" do
    credential_name = unique_name("claude-oauth")

    raw_json =
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-oat01-usage",
          "refreshToken" => "sk-ant-ort01-refresh",
          "expiresAt" => System.system_time(:millisecond) + 60 * 60 * 1000,
          "scopes" => ["user:inference"],
          "subscriptionType" => "max"
        },
        "organizationUuid" => "org-usage"
      })

    {:ok, _credential} = Credentials.import_cli_auth(credential_name, raw_json)

    Req.Test.stub(ClaudeCode, fn conn ->
      assert {"authorization", "Bearer sk-ant-oat01-usage"} in conn.req_headers
      assert {"anthropic-beta", "oauth-2025-04-20"} in conn.req_headers

      body = %{
        "five_hour" => %{
          "utilization" => 2.0,
          "resets_at" => "2026-06-08T19:50:00.292521+00:00"
        },
        "seven_day" => %{
          "utilization" => 1.0,
          "resets_at" => "2026-06-14T02:00:00.292549+00:00"
        },
        "extra_usage" => %{"is_enabled" => false}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    plan = %Plan{
      provider: "claude_code",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "claude_code"
    assert result.usage["five_hour"]["utilization"] == 2.0
    assert result.usage["seven_day"]["utilization"] == 1.0
  end

  test "fetch_usage/1 rejects plain LLM credentials for Claude Code" do
    credential_name = unique_name("claude-key")
    Vault.put(%Credential{name: credential_name, kind: "llm", encrypted_value: <<>>})
    on_exit(fn -> Vault.remove(credential_name) end)

    plan = %Plan{provider: "claude_code", credential_name: credential_name, config: %{}}

    assert {:error, {:invalid_credential_auth_type, "api_key", "anthropic_oauth"}} =
             UsageFetcher.fetch_usage(plan)
  end

  test "fetch_usage/1 fetches OpenAI Codex usage with OAuth metadata account ID" do
    credential_name = unique_name("openai-codex")

    {:ok, _credential} =
      Credentials.store_device_token(
        credential_name,
        "openai_oauth",
        openai_token_set("old-access", "refresh-token", "acc-123"),
        %{"account_id" => "acc-123"}
      )

    Req.Test.stub(OpenAICodex, fn conn ->
      assert {"authorization", "Bearer old-access"} in conn.req_headers
      assert {"chatgpt-account-id", "acc-123"} in conn.req_headers

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(openai_usage_body()))
    end)

    plan = %Plan{
      provider: "openai_codex",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "openai_codex"
    assert result.plan_type == "plus"
    assert result.limits["codex"].primary.used_percent == 25
  end

  test "fetch_usage/1 reads OpenAI Codex account ID from encrypted token blob" do
    credential_name = unique_name("openai-codex-token-account")

    {:ok, _credential} =
      Credentials.store_device_token(
        credential_name,
        "openai_oauth",
        openai_token_set("old-access", "refresh-token", "acc-token-only")
      )

    Req.Test.stub(OpenAICodex, fn conn ->
      assert {"authorization", "Bearer old-access"} in conn.req_headers
      assert {"chatgpt-account-id", "acc-token-only"} in conn.req_headers

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(openai_usage_body()))
    end)

    plan = %Plan{
      provider: "openai_codex",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "openai_codex"
    assert result.plan_type == "plus"
  end

  test "fetch_usage/1 reads OpenAI Codex account ID from token claims" do
    credential_name = unique_name("openai-codex-claim-account")

    {:ok, _credential} =
      Credentials.store_device_token(
        credential_name,
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "old-access",
          "refresh_token" => "refresh-token",
          "id_token" => jwt(%{"profile" => %{"chatgpt_account_id" => "acc-claim-only"}}),
          "expires_at" => System.system_time(:millisecond) + 60 * 60 * 1000,
          "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )

    Req.Test.stub(OpenAICodex, fn conn ->
      assert {"authorization", "Bearer old-access"} in conn.req_headers
      assert {"chatgpt-account-id", "acc-claim-only"} in conn.req_headers

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(openai_usage_body()))
    end)

    plan = %Plan{
      provider: "openai_codex",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "openai_codex"
    assert result.plan_type == "plus"
  end

  test "fetch_usage/1 reads OpenAI Codex account ID from refreshed token claims" do
    credential_name = unique_name("openai-codex-refreshed-claim")
    prior_refresher = Application.get_env(:backplane, OAuthRefresher, [])

    {:ok, refresh_pid} = Bandit.start_link(plug: OpenAIRefreshEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(refresh_pid)

    Application.put_env(:backplane, OAuthRefresher,
      openai_token_url: "http://localhost:#{port}/openai/token"
    )

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior_refresher)

      try do
        ThousandIsland.stop(refresh_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, _credential} =
      Credentials.store_device_token(
        credential_name,
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "access_token" => "old-access",
          "refresh_token" => "old-refresh",
          "expires_at" => System.system_time(:millisecond) + 60 * 60 * 1000
        }
      )

    Req.Test.stub(OpenAICodex, fn conn ->
      assert {"authorization", "Bearer new-access"} in conn.req_headers
      assert {"chatgpt-account-id", "acc-refreshed"} in conn.req_headers

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(openai_usage_body()))
    end)

    plan = %Plan{
      provider: "openai_codex",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "openai_codex"
    assert result.plan_type == "plus"
  end

  test "fetch_usage/1 rejects non-OpenAI OAuth credentials for OpenAI Codex" do
    credential_name = unique_name("plain-key")

    Vault.put(%Credential{
      name: credential_name,
      kind: "llm",
      encrypted_value: <<>>,
      metadata: %{"auth_type" => "api_key"}
    })

    on_exit(fn -> Vault.remove(credential_name) end)

    plan = %Plan{
      provider: "openai_codex",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:error, {:invalid_credential_auth_type, "api_key", "openai_oauth"}} =
             UsageFetcher.fetch_usage(plan)
  end

  test "fetch_usage/1 refreshes OpenAI Codex token once after 401" do
    credential_name = unique_name("openai-codex-retry")
    prior_refresher = Application.get_env(:backplane, OAuthRefresher, [])

    {:ok, refresh_pid} = Bandit.start_link(plug: OpenAIRefreshEndpoint, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(refresh_pid)

    Application.put_env(:backplane, OAuthRefresher,
      openai_token_url: "http://localhost:#{port}/openai/token"
    )

    {:ok, call_count} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      Application.put_env(:backplane, OAuthRefresher, prior_refresher)

      if Process.alive?(call_count) do
        Agent.stop(call_count)
      end

      try do
        ThousandIsland.stop(refresh_pid)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, _credential} =
      Credentials.store_device_token(
        credential_name,
        "openai_oauth",
        openai_token_set("old-access", "old-refresh", "acc-123"),
        %{"account_id" => "acc-123"}
      )

    Req.Test.stub(OpenAICodex, fn conn ->
      count = Agent.get_and_update(call_count, &{&1, &1 + 1})

      case count do
        0 ->
          assert {"authorization", "Bearer old-access"} in conn.req_headers
          Plug.Conn.send_resp(conn, 401, "Unauthorized")

        1 ->
          assert {"authorization", "Bearer new-access"} in conn.req_headers

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(openai_usage_body()))
      end
    end)

    plan = %Plan{
      provider: "openai_codex",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "openai_codex"
    assert Agent.get(call_count, & &1) == 2
  end

  test "fetch_usage/1 fetches Google Antigravity usage with Google OAuth credentials" do
    credential_name = unique_name("google-antigravity")

    {:ok, _credential} =
      Credentials.store_device_token(
        credential_name,
        "google_oauth",
        google_token_set("google-access", "google-refresh"),
        %{"auth_mode" => "antigravity"}
      )

    Req.Test.stub(GoogleAntigravity, fn conn ->
      assert {"authorization", "Bearer google-access"} in conn.req_headers

      assert conn.request_path ==
               "/google.internal.cloud.code.v1internal.PredictionService/RetrieveUserQuota"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(google_antigravity_usage_body()))
    end)

    plan = %Plan{
      provider: "google_ai",
      credential_name: credential_name,
      config: %{"project" => "projects/test-project"},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "google_ai"
    assert result.plan_type == "google one ai pro"
    assert [%{id: "prompt", used_percent: 20} | _] = result.credits
  end

  test "fetch_usage/1 rejects non-Google OAuth credentials for Google Antigravity" do
    credential_name = unique_name("google-antigravity-key")

    Vault.put(%Credential{
      name: credential_name,
      kind: "llm",
      encrypted_value: <<>>,
      metadata: %{"auth_type" => "api_key"}
    })

    on_exit(fn -> Vault.remove(credential_name) end)

    plan = %Plan{
      provider: "google_ai",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:error, {:invalid_credential_auth_type, "api_key", "google_oauth"}} =
             UsageFetcher.fetch_usage(plan)
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp openai_token_set(access_token, refresh_token, account_id) do
    %{
      "type" => "codex_device_oauth",
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_at" => System.system_time(:millisecond) + 60 * 60 * 1000,
      "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "account_id" => account_id
    }
  end

  defp openai_usage_body do
    %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 25,
          "limit_window_seconds" => 18_000,
          "reset_at" => 1_760_000_000
        }
      }
    }
  end

  defp google_token_set(access_token, refresh_token) do
    %{
      "type" => "google_antigravity_oauth",
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_at" => System.system_time(:millisecond) + 60 * 60 * 1000,
      "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp google_antigravity_usage_body do
    %{
      "plan_status" => %{
        "plan_info" => %{
          "plan_name" => "google one ai pro",
          "monthly_prompt_credits" => 1000,
          "monthly_flow_credits" => 500
        },
        "available_prompt_credits" => 800,
        "used_prompt_credits" => 200,
        "available_flow_credits" => 400,
        "used_flow_credits" => 100
      }
    }
  end

  defp jwt(payload) do
    encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded_payload}.sig"
  end
end
