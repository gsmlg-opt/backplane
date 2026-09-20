defmodule Backplane.Monitor.Providers.WebUsageTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.{Exa, Firecrawl, Tavily}

  setup do
    for {option, provider} <- [tavily_req_options: Tavily, firecrawl_req_options: Firecrawl] do
      previous = Application.get_env(:backplane_monitor, option)
      Application.put_env(:backplane_monitor, option, plug: {Req.Test, provider})

      on_exit(fn ->
        if previous,
          do: Application.put_env(:backplane_monitor, option, previous),
          else: Application.delete_env(:backplane_monitor, option)
      end)
    end

    :ok
  end

  test "Tavily returns key and account usage" do
    Req.Test.stub(Tavily, fn conn ->
      assert conn.request_path == "/usage"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tavily-key"]

      Req.Test.json(conn, %{
        key: %{usage: 3, limit: 10, search_usage: 2},
        account: %{usage: 4}
      })
    end)

    assert {:ok, %{is_available: true, limit: %{amount: "10"}, usage: usage}} =
             Tavily.fetch("tavily-key")

    assert Enum.map(usage, & &1.label) == ["Key Total", "Key Search", "Account Total"]
  end

  test "Firecrawl returns remaining and plan credits" do
    Req.Test.stub(Firecrawl, fn conn ->
      assert conn.request_path == "/v2/team/credit-usage"

      Req.Test.json(conn, %{
        success: true,
        data: %{remainingCredits: 12, planCredits: 100, billingPeriodEnd: "2026-10-01T00:00:00Z"}
      })
    end)

    assert {:ok, %{is_available: true, usage: [], limit: limit}} =
             Firecrawl.fetch("firecrawl-key")

    assert limit == %{
             amount: "100",
             remaining: "12",
             currency: "credits",
             reset: "2026-10-01T00:00:00Z"
           }
  end

  test "Exa reports the documented service-key limitation" do
    assert {:ok, %{usage: [], warnings: [{:usage_unavailable, :team_management_key_required}]}} =
             Exa.fetch()
  end
end
