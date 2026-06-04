defmodule Backplane.Monitor.UsageFetcherTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.Providers.OpenAICodex
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

    previous = Application.get_env(:backplane, :openai_codex_monitor_req_options)

    Application.put_env(:backplane, :openai_codex_monitor_req_options,
      plug: {Req.Test, OpenAICodex}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :openai_codex_monitor_req_options, previous)
      else
        Application.delete_env(:backplane, :openai_codex_monitor_req_options)
      end
    end)

    :ok
  end

  test "fetch_usage/1 runs Claude Code script credentials" do
    credential_name = unique_name("claude-script")
    usage = %{"subscription" => "max", "tokens" => %{"used" => 9, "limit" => 20}}

    {:ok, _credential} = Credentials.store(credential_name, usage_script(usage), "script")

    plan = %Plan{
      provider: "claude_code",
      credential_name: credential_name,
      config: %{},
      active: true
    }

    assert {:ok, result} = UsageFetcher.fetch_usage(plan)
    assert result.provider == "claude_code"
    assert result.usage == usage
  end

  test "fetch_usage/1 rejects non-script credentials for Claude Code" do
    credential_name = unique_name("claude-key")
    Vault.put(%Credential{name: credential_name, kind: "llm", encrypted_value: <<>>})
    on_exit(fn -> Vault.remove(credential_name) end)

    plan = %Plan{provider: "claude_code", credential_name: credential_name, config: %{}}

    assert {:error, {:invalid_credential_kind, "llm", "script"}} = UsageFetcher.fetch_usage(plan)
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

  defp usage_script(usage) do
    """
    const response = await fetch("#{data_url(usage)}");
    const data = await response.json();
    return data;
    """
  end

  defp data_url(payload) do
    "data:application/json;base64,#{payload |> Jason.encode!() |> Base.encode64()}"
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

  defp jwt(payload) do
    encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded_payload}.sig"
  end
end
