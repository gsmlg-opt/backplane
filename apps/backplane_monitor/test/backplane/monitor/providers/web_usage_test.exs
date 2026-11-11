defmodule Backplane.Monitor.Providers.WebUsageTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Providers.{Exa, Firecrawl, Tavily}

  setup do
    HTTP.Test.verify_on_exit!()

    for {option, provider} <- [tavily_http_options: Tavily, firecrawl_http_options: Firecrawl] do
      previous = Application.get_env(:backplane_monitor, option)
      Application.put_env(:backplane_monitor, option, adapter: {HTTP.Test, provider})

      on_exit(fn ->
        if previous,
          do: Application.put_env(:backplane_monitor, option, previous),
          else: Application.delete_env(:backplane_monitor, option)
      end)
    end

    :ok
  end

  test "Tavily returns key and account usage" do
    HTTP.Test.stub(Tavily, fn request ->
      assert request.url.path == "/usage"
      assert HTTP.Headers.get_all(request.headers, "authorization") == ["Bearer tavily-key"]

      HTTP.Test.json(%{
        key: %{usage: 3, limit: 10, search_usage: 2},
        account: %{usage: 4}
      })
    end)

    assert {:ok, %{is_available: true, limit: %{amount: "10"}, usage: usage}} =
             Tavily.fetch("tavily-key")

    assert Enum.map(usage, & &1.label) == ["Key Total", "Key Search", "Account Total"]
  end

  test "Firecrawl returns remaining and plan credits" do
    HTTP.Test.stub(Firecrawl, fn request ->
      assert request.url.path == "/v2/team/credit-usage"

      HTTP.Test.json(%{
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
