defmodule Backplane.MonitorTest do
  use ExUnit.Case, async: false

  alias Backplane.Monitor
  alias Backplane.Monitor.PlanServer

  setup tags do
    BackplaneDataCase.setup_sandbox(Backplane.Repo, tags)
    :ok
  end

  test "plan CRUD keeps the plan process lifecycle in sync" do
    {:ok, plan} =
      Monitor.create_plan(%{
        name: unique_name("google-ai-plan"),
        provider: "google_ai",
        credential_name: "unused",
        active: true
      })

    assert pid = PlanServer.whereis(plan.id)
    assert %{usage: {:unsupported, "google_ai"}} = PlanServer.state(pid)

    {:ok, paused_plan} = Monitor.update_plan(plan, %{active: false})
    assert %{plan: %{active: false}} = PlanServer.state(paused_plan.id)

    assert {:ok, _deleted_plan} = Monitor.delete_plan(paused_plan)
    assert_process_stopped(plan.id)
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp assert_process_stopped(plan_id, attempts \\ 10)
  defp assert_process_stopped(plan_id, 0), do: refute(PlanServer.whereis(plan_id))

  defp assert_process_stopped(plan_id, attempts) do
    case PlanServer.whereis(plan_id) do
      nil ->
        assert true

      _pid ->
        Process.sleep(10)
        assert_process_stopped(plan_id, attempts - 1)
    end
  end
end
