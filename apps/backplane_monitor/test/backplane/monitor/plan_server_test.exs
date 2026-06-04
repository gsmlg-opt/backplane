defmodule Backplane.Monitor.PlanServerTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor.Plan
  alias Backplane.Monitor.PlanServer

  setup_all do
    Application.ensure_all_started(:backplane_monitor)
    :ok
  end

  test "active plan stores usage and refreshes on interval" do
    plan = plan(active: true)

    pid = start_supervised!({PlanServer, plan: plan, refresh_interval: 20})

    first = PlanServer.state(pid)
    assert first.plan == plan
    assert first.usage == {:unsupported, "google_ai"}
    assert %DateTime{} = first.fetched_at

    Process.sleep(60)

    second = PlanServer.state(pid)
    assert DateTime.diff(second.fetched_at, first.fetched_at, :microsecond) > 0
  end

  test "paused plan does not auto refresh" do
    plan = plan(active: false)

    pid = start_supervised!({PlanServer, plan: plan, refresh_interval: 20})

    first = PlanServer.state(pid)
    assert first.plan == plan
    assert first.usage == nil
    assert first.fetched_at == nil

    Process.sleep(60)

    assert PlanServer.state(pid) == first
  end

  defp plan(attrs) do
    attrs = Map.new(attrs)

    struct!(
      Plan,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          name: "Plan #{System.unique_integer([:positive])}",
          provider: "google_ai",
          credential_name: "unused",
          config: %{},
          active: true
        },
        attrs
      )
    )
  end
end
