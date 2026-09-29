defmodule Backplane.AgentRuntime.CT05CollaborationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{AgentHost, Collaboration, Error}

  defp host(profile) do
    {:ok, host} = AgentHost.new("ct05", %{max_agents: 8, max_active_runs: 8})

    {:ok, host, _} =
      AgentHost.register(host, %{agent_id: "parent", lifecycle: :hosted, owner: nil})

    {:ok, host, _} = AgentHost.submit(host, "parent", %{run_id: "parent-run"})

    {:ok, host, _} =
      Collaboration.register_tools(host,
        profile: profile,
        tools: Collaboration.profile_tools(profile)
      )

    host
  end

  test "messages derive sender from parent run and reject forged sender" do
    host = host(:v2)

    {:ok, host, _} =
      AgentHost.register(host, %{agent_id: "target", lifecycle: :hosted, owner: nil})

    request = %{
      parent_run_id: "parent-run",
      recipient: "target",
      kind: :notification,
      correlation_id: "c1",
      payload: %{"value" => 1},
      expires_at: 100
    }

    assert {:ok, host, _} = Collaboration.send_message(host, request)
    assert host.inboxes["target"].accepted["c1"]

    assert {:error, %Error{class: :forbidden}} =
             Collaboration.send_message(host, Map.put(request, :sender, "forged"))

    assert {:error, %Error{class: :resource_conflict}} =
             Collaboration.send_message(
               host,
               request |> Map.put(:sender, "parent") |> Map.put(:payload, %{"value" => 2})
             )
  end

  test "v1 spawn, wait and close cancel owned children but preserve hosted peers" do
    host = host(:v1)
    {:ok, host, _} = AgentHost.register(host, %{agent_id: "peer", lifecycle: :hosted, owner: nil})

    {:ok, host, receipt} =
      Collaboration.spawn_agent(host, %{
        parent_run_id: "parent-run",
        agent_id: "child",
        run_id: "child-run"
      })

    assert receipt.run_id == "child-run"

    assert {:ok, %{status: :waiting}} =
             Collaboration.wait_agent(host, %{parent_run_id: "parent-run", run_id: "child-run"})

    assert {:ok, closed, %{status: :closed, cancelled: cancelled}} =
             Collaboration.close_agent(host, %{parent_run_id: "parent-run", run_id: "child-run"})

    assert "child-run" in cancelled
    assert closed.runs["child-run"].status == :cancelled
    assert closed.agents["child"].status == :stopped
    assert closed.agents["peer"].status == :active
  end

  test "v2 interrupt is profile-gated and cross-owner close is denied" do
    host = host(:v2)

    {:ok, host, _} =
      Collaboration.spawn_agent(host, %{
        parent_run_id: "parent-run",
        agent_id: "child",
        run_id: "child-run"
      })

    assert {:ok, interrupted, %{status: :cancelled}} =
             Collaboration.interrupt_agent(host, %{
               parent_run_id: "parent-run",
               run_id: "child-run"
             })

    assert interrupted.runs["child-run"].status == :cancelled

    v1_host = host(:v1)

    {:ok, v1_host, _} =
      Collaboration.spawn_agent(v1_host, %{
        parent_run_id: "parent-run",
        agent_id: "child",
        run_id: "child-run"
      })

    assert {:error, %Error{class: :forbidden}} =
             Collaboration.close_agent(v1_host, %{parent_run_id: "other-run", run_id: "child-run"})
  end
end
