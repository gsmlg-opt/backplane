defmodule BackplaneWeb.DashboardPlanUsageLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Repo
  alias Backplane.Settings.Credentials
  alias Backplane.Monitor.Providers.{GoogleAntigravity, MiniMax, OpenAICodex}

  setup do
    previous_minimax = Application.get_env(:backplane, :minimax_monitor_req_options)
    previous_openai = Application.get_env(:backplane, :openai_codex_monitor_req_options)
    previous_google = Application.get_env(:backplane, :google_antigravity_monitor_req_options)
    previous_req_test_owner = Application.get_env(:backplane_monitor, :req_test_owner)

    Application.put_env(:backplane, :minimax_monitor_req_options, plug: {Req.Test, MiniMax})

    Application.put_env(:backplane, :openai_codex_monitor_req_options,
      plug: {Req.Test, OpenAICodex}
    )

    Application.put_env(:backplane, :google_antigravity_monitor_req_options,
      plug: {Req.Test, GoogleAntigravity}
    )

    Application.put_env(:backplane_monitor, :req_test_owner, self())

    Ecto.Adapters.SQL.Sandbox.allow(Backplane.Repo, self(), Backplane.Settings.Credentials.Vault)

    res = Credentials.store("minimax-test-cred", "mock-api-key", "service")
    IO.puts("STORE RESULT: #{inspect(res)}")

    {:ok, plan} =
      Repo.insert(%Plan{
        name: "My MiniMax Plan",
        provider: "minimax",
        credential_name: "minimax-test-cred",
        active: true
      })

    on_exit(fn ->
      if previous_minimax do
        Application.put_env(:backplane, :minimax_monitor_req_options, previous_minimax)
      else
        Application.delete_env(:backplane, :minimax_monitor_req_options)
      end

      if previous_openai do
        Application.put_env(:backplane, :openai_codex_monitor_req_options, previous_openai)
      else
        Application.delete_env(:backplane, :openai_codex_monitor_req_options)
      end

      if previous_google do
        Application.put_env(:backplane, :google_antigravity_monitor_req_options, previous_google)
      else
        Application.delete_env(:backplane, :google_antigravity_monitor_req_options)
      end

      if previous_req_test_owner do
        Application.put_env(:backplane_monitor, :req_test_owner, previous_req_test_owner)
      else
        Application.delete_env(:backplane_monitor, :req_test_owner)
      end
    end)

    {:ok, plan: plan}
  end

  test "renders MiniMax plan usage details with current and weekly remaining percents and time ranges",
       %{conn: conn} do
    Req.Test.stub(MiniMax, fn conn ->
      body = %{
        "model_remains" => [
          %{
            "start_time" => 1_780_434_000_000,
            "end_time" => 1_780_452_000_000,
            "remains_time" => 60284,
            "current_interval_total_count" => 0,
            "current_interval_usage_count" => 0,
            "model_name" => "general",
            "current_weekly_total_count" => 0,
            "current_weekly_usage_count" => 0,
            "weekly_start_time" => 1_780_243_200_000,
            "weekly_end_time" => 1_780_848_000_000,
            "weekly_remains_time" => 396_060_284,
            "current_interval_status" => 1,
            "current_interval_remaining_percent" => 97,
            "current_weekly_status" => 1,
            "current_weekly_remaining_percent" => 96,
            "interval_boost_permille" => 2000,
            "weekly_boost_permille" => 3000
          }
        ],
        "base_resp" => %{
          "status_code" => 0,
          "status_msg" => "success"
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    # Ensure the credential is in the Vault ETS cache right before rendering
    cred = Repo.get_by!(Backplane.Settings.Credential, name: "minimax-test-cred")
    Backplane.Settings.Credentials.Vault.put(cred)

    {:ok, _view, html} = live(conn, "/admin/dashboard/usage/plans")
    assert html =~ "My MiniMax Plan"
    assert html =~ "general"
    assert html =~ "94% remaining"
    assert html =~ "88% remaining"
    assert html =~ "1m 0s left"
    assert html =~ "4d 14h left"
  end

  test "renders Claude Code script usage windows", %{conn: conn} do
    Req.Test.stub(MiniMax, fn conn ->
      body = %{"model_remains" => []}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    usage = %{
      "cinder_cove" => nil,
      "extra_usage" => %{
        "currency" => nil,
        "disabled_reason" => nil,
        "is_enabled" => false,
        "monthly_limit" => nil,
        "used_credits" => nil,
        "utilization" => nil
      },
      "five_hour" => %{
        "resets_at" => "2026-06-04T04:10:00.305182+00:00",
        "utilization" => 85
      },
      "iguana_necktie" => nil,
      "omelette_promotional" => nil,
      "seven_day" => %{
        "resets_at" => "2026-06-07T02:00:00.305205+00:00",
        "utilization" => 73
      },
      "seven_day_cowork" => nil,
      "seven_day_oauth_apps" => nil,
      "seven_day_omelette" => nil,
      "seven_day_opus" => nil,
      "seven_day_sonnet" => nil,
      "tangelo" => nil
    }

    {:ok, credential} =
      Credentials.store("claude-code-script-cred", usage_script(usage), "script")

    Backplane.Settings.Credentials.Vault.put(credential)

    {:ok, _plan} =
      Repo.insert(%Plan{
        name: "My Claude Code Plan",
        provider: "claude_code",
        credential_name: "claude-code-script-cred",
        active: true
      })

    {:ok, _view, html} = live(conn, "/admin/dashboard/usage/plans")
    assert html =~ "My Claude Code Plan"
    assert html =~ "Claude Code"
    assert html =~ "5-hour"
    assert html =~ "85% used"
    assert html =~ "06/04 04:10 UTC"
    assert html =~ "7-day"
    assert html =~ "73% used"
    assert html =~ "06/07 02:00 UTC"
    assert html =~ "Extra Usage"
    assert html =~ "Disabled"
  end

  test "renders OpenAI Codex usage buckets and credits", %{conn: conn} do
    Req.Test.stub(MiniMax, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"model_remains" => []}))
    end)

    Req.Test.stub(OpenAICodex, fn conn ->
      assert {"authorization", "Bearer codex-access"} in conn.req_headers
      assert {"chatgpt-account-id", "acc-123"} in conn.req_headers

      body = %{
        "plan_type" => "plus",
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 25,
            "limit_window_seconds" => 18_000,
            "reset_at" => 1_760_000_000
          },
          "secondary_window" => %{
            "used_percent" => 10,
            "limit_window_seconds" => 604_800,
            "reset_at" => 1_760_500_000
          }
        },
        "credits" => %{
          "has_credits" => true,
          "unlimited" => false,
          "balance" => "9.99"
        },
        "additional_rate_limits" => [
          %{
            "metered_feature" => "codex_other",
            "limit_name" => "codex_other",
            "rate_limit" => %{
              "primary_window" => %{
                "used_percent" => 42,
                "limit_window_seconds" => 3600,
                "reset_at" => 1_760_001_000
              }
            }
          }
        ],
        "rate_limit_reached_type" => %{"type" => "rate_limit_reached"}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    {:ok, credential} =
      Credentials.store_device_token(
        "openai-codex-test-cred",
        "openai_oauth",
        openai_token_set("codex-access", "codex-refresh", "acc-123"),
        %{"account_id" => "acc-123"}
      )

    Backplane.Settings.Credentials.Vault.put(credential)

    {:ok, _plan} =
      Repo.insert(%Plan{
        name: "My Codex Plan",
        provider: "openai_codex",
        credential_name: "openai-codex-test-cred",
        active: true
      })

    {:ok, _view, html} = live(conn, "/admin/dashboard/usage/plans")
    assert html =~ "My Codex Plan"
    assert html =~ "OpenAI Codex"
    assert html =~ "Plus"
    assert html =~ "Codex"
    assert html =~ "codex_other"
    assert html =~ "25% used"
    assert html =~ "42% used"
    assert html =~ "9.99"
    assert html =~ "rate_limit_reached"
  end

  test "renders Google Antigravity model quota buckets as supported usage groups", %{conn: conn} do
    Req.Test.stub(MiniMax, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"model_remains" => []}))
    end)

    Req.Test.stub(GoogleAntigravity, fn conn ->
      assert {"authorization", "Bearer google-access"} in conn.req_headers

      assert conn.request_path ==
               "/google.internal.cloud.code.v1internal.PredictionService/RetrieveUserQuota"

      body = %{
        "buckets" => [
          %{
            "model" => %{"model_id" => "claude-opus-4-6-thinking"},
            "token_type" => "wtus",
            "remaining_fraction" => 0.4
          },
          %{
            "model" => %{"model_id" => "gpt-oss-120b"},
            "token_type" => "wtus",
            "remaining_fraction" => 0.7
          },
          %{
            "model" => %{"model_id" => "gemini-3.1-pro-high"},
            "token_type" => "wtus",
            "remaining_fraction" => 0.8
          },
          %{
            "model" => %{"model_id" => "gemini-3.5-flash-low"},
            "token_type" => "wtus",
            "remaining_fraction" => 1.0
          },
          %{
            "model" => %{"model_id" => "gemini-2.5-flash"},
            "token_type" => "wtus",
            "remaining_fraction" => 0.1
          },
          %{
            "model" => %{"model_id" => "chat_20706"},
            "token_type" => "wtus",
            "remaining_fraction" => 0.1
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    {:ok, credential} =
      Credentials.store_device_token(
        "google-antigravity-test-cred",
        "google_oauth",
        google_token_set("google-access", "google-refresh"),
        %{"auth_mode" => "antigravity"}
      )

    Backplane.Settings.Credentials.Vault.put(credential)

    {:ok, _plan} =
      Repo.insert(%Plan{
        name: "My Google Antigravity Plan",
        provider: "google_ai",
        credential_name: "google-antigravity-test-cred",
        config: %{"project" => "projects/test-project"},
        active: true
      })

    {:ok, _view, html} = live(conn, "/admin/dashboard/usage/plans")
    assert html =~ "My Google Antigravity Plan"
    assert html =~ "Google Antigravity"
    assert html =~ "Usage Groups"
    assert html =~ "Gemini Models"
    assert html =~ "Claude / GPT-OSS Models"
    assert html =~ "60% used"
    assert html =~ "20% used"
    assert html =~ "0% used"
    refute html =~ "Other Models"
    refute html =~ "claude-opus-4-6-thinking"
    refute html =~ "gpt-oss-120b"
    refute html =~ "gemini-3.1-pro-high"
    refute html =~ "gemini-3.5-flash-low"
    refute html =~ "gemini-2.5-flash"
    refute html =~ "chat_20706"
    assert html =~ "Credits"
    assert html =~ "Activity"
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

  defp google_token_set(access_token, refresh_token) do
    %{
      "type" => "google_antigravity_oauth",
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_at" => System.system_time(:millisecond) + 60 * 60 * 1000,
      "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
