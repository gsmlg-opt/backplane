defmodule Backplane.Admin.LiveCaseTest do
  use Backplane.Admin.LiveCase, async: false

  alias Phoenix.SessionProcess.{Config, RateLimiter}

  setup_all do
    :ok = RateLimiter.reset()

    for _ <- 1..Config.rate_limit() do
      :ok = RateLimiter.check_rate_limit()
    end

    assert {:error, :rate_limit_exceeded} = RateLimiter.check_rate_limit()
    on_exit(fn -> RateLimiter.reset() end)
    :ok
  end

  test "a browser session starts when an earlier test exhausted the creation budget", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/system/appearance")

    assert has_element?(view, "h1", "Appearance")
  end
end
