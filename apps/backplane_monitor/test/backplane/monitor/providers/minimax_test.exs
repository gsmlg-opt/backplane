defmodule Backplane.Monitor.Providers.MiniMaxTest do
  use ExUnit.Case, async: true

  alias Backplane.Monitor.Providers.MiniMax

  setup do
    previous = Application.get_env(:backplane, :minimax_monitor_req_options)
    Application.put_env(:backplane, :minimax_monitor_req_options, plug: {Req.Test, MiniMax})

    on_exit(fn ->
      if previous do
        Application.put_env(:backplane, :minimax_monitor_req_options, previous)
      else
        Application.delete_env(:backplane, :minimax_monitor_req_options)
      end
    end)

    :ok
  end

  test "fetch/2 returns parsed data for the old/counting format" do
    Req.Test.stub(MiniMax, fn conn ->
      assert conn.request_path == "/v1/api/openplatform/coding_plan/remains"
      assert {"authorization", "Bearer test-key"} in conn.req_headers

      body = %{
        "model_remains" => [
          %{
            "model_name" => "text_generation",
            "current_interval_usage_count" => 1380,
            "current_interval_total_count" => 1500,
            "next_reset_time" => 1_748_400_000_000,
            "weekly_usage_count" => 11000,
            "weekly_total_count" => 15000
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    assert {:ok, result} = MiniMax.fetch("test-key")
    assert result.provider == "minimax"
    assert [model] = result.models
    assert model.name == "text_generation"
    assert model.total == 1500
    assert model.remaining == 1380
    assert model.used == 120
    assert model.weekly_total == 15000
    assert model.weekly_remaining == 11000
    assert model.weekly_used == 4000
    assert model.next_reset == DateTime.from_unix!(1_748_400_000)
  end

  test "fetch/2 returns parsed data for the new/percent format" do
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

    assert {:ok, result} = MiniMax.fetch("test-key")
    assert result.provider == "minimax"
    assert [model] = result.models
    assert model.name == "general"
    assert model.total == 100
    assert model.remaining == 94
    assert model.used == 6
    assert model.weekly_total == 100
    assert model.weekly_remaining == 88
    assert model.weekly_used == 12
    assert model.next_reset == DateTime.from_unix!(1_780_452_000)
    assert model.current_interval_remaining_percent == 94
    assert model.current_weekly_remaining_percent == 88
    assert model.start_time == DateTime.from_unix!(1_780_434_000)
    assert model.end_time == DateTime.from_unix!(1_780_452_000)
    assert model.remains_time == 60284
    assert model.weekly_start_time == DateTime.from_unix!(1_780_243_200)
    assert model.weekly_end_time == DateTime.from_unix!(1_780_848_000)
    assert model.weekly_remains_time == 396_060_284
  end

  test "fetch/2 handles API errors" do
    Req.Test.stub(MiniMax, fn conn ->
      Plug.Conn.send_resp(conn, 401, "Unauthorized")
    end)

    assert {:error, {:api_error, 401, "Unauthorized"}} = MiniMax.fetch("test-key")
  end
end
