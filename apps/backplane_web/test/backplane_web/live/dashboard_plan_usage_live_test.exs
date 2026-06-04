defmodule BackplaneWeb.DashboardPlanUsageLiveTest do
  use Backplane.LiveCase, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Repo
  alias Backplane.Settings.Credentials
  alias Backplane.Monitor.Providers.MiniMax

  setup do
    previous = Application.get_env(:backplane, :minimax_monitor_req_options)
    Application.put_env(:backplane, :minimax_monitor_req_options, plug: {Req.Test, MiniMax})

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
      if previous do
        Application.put_env(:backplane, :minimax_monitor_req_options, previous)
      else
        Application.delete_env(:backplane, :minimax_monitor_req_options)
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
end
