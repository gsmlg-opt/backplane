defmodule Backplane.Monitor.Providers.OpenAICodexTest do
  use ExUnit.Case, async: true

  alias Backplane.Monitor.Providers.OpenAICodex

  setup do
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

  test "fetch/2 sends Codex OAuth headers and returns normalized usage" do
    Req.Test.stub(OpenAICodex, fn conn ->
      assert conn.request_path == "/backend-api/wham/usage"
      assert {"authorization", "Bearer access-token"} in conn.req_headers
      assert {"chatgpt-account-id", "acc-123"} in conn.req_headers
      assert {"user-agent", "codex-cli"} in conn.req_headers
      assert {"accept", "application/json"} in conn.req_headers

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
                "used_percent" => 42.5,
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

    assert {:ok, result} =
             OpenAICodex.fetch("access-token", %{"chatgpt_account_id" => "acc-123"})

    assert result.provider == "openai_codex"
    assert result.status == "ok"
    assert result.plan_type == "plus"

    assert %{"codex" => codex, "codex_other" => other} = result.limits
    assert codex.primary.used_percent == 25
    assert codex.primary.window_duration_mins == 300
    assert codex.primary.resets_at == 1_760_000_000
    assert codex.secondary.used_percent == 10
    assert codex.secondary.window_duration_mins == 10_080
    assert codex.credits.balance == "9.99"
    assert codex.rate_limit_reached_type == "rate_limit_reached"

    assert other.limit_id == "codex_other"
    assert other.limit_name == "codex_other"
    assert other.primary.used_percent == 42.5
    assert other.primary.window_duration_mins == 60
    assert other.primary.resets_at == 1_760_001_000
    assert is_nil(other.secondary)
    assert is_nil(other.credits)
  end

  test "fetch/2 requires ChatGPT account ID" do
    assert {:error, :missing_chatgpt_account_id} = OpenAICodex.fetch("access-token", %{})
  end

  test "fetch/2 maps 401 to unauthorized" do
    Req.Test.stub(OpenAICodex, fn conn ->
      Plug.Conn.send_resp(conn, 401, "Unauthorized")
    end)

    assert {:error, :unauthorized} =
             OpenAICodex.fetch("access-token", %{"chatgpt_account_id" => "acc-123"})
  end

  test "fetch/2 maps 429 retry-after" do
    Req.Test.stub(OpenAICodex, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "60")
      |> Plug.Conn.send_resp(429, "Too Many Requests")
    end)

    assert {:error, {:rate_limited, 60}} =
             OpenAICodex.fetch("access-token", %{"chatgpt_account_id" => "acc-123"})
  end

  test "normalize_usage_response/1 rejects unrecognized bodies" do
    assert {:error, :invalid_usage_response} = OpenAICodex.normalize_usage_response(%{})
  end
end
