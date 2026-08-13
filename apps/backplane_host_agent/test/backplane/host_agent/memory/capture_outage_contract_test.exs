defmodule Backplane.HostAgent.Memory.CaptureOutageContractTest do
  use ExUnit.Case, async: false

  alias Backplane.HostAgent.Memory.{CaptureSupervisor, CaptureUploader}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.HostAgent.MemoryRouter

  import Plug.Conn
  import Plug.Test

  @moduletag :tmp_dir

  defmodule ChannelProvider do
    def channel, do: :persistent_term.get({__MODULE__, :channel}, nil)
  end

  defmodule AcceptingChannel do
    def push(channel, "memory_events", payload) do
      send(channel, {:memory_events, payload})

      {:ok,
       %{
         "batch_id" => payload["batch_id"],
         "results" =>
           Enum.map(payload["events"], fn event ->
             %{
               "event_id" => event["event_id"],
               "status" => "accepted",
               "server_event_id" => "server-#{event["event_id"]}"
             }
           end)
       }}
    end
  end

  setup do
    previous_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)
    :persistent_term.put({ChannelProvider, :channel}, nil)

    on_exit(fn ->
      :persistent_term.erase({ChannelProvider, :channel})
      restore_env(:capture_runtime, previous_runtime)
    end)
  end

  test "accepted Claude hooks survive a 24-hour outage and drain after restart", %{tmp_dir: dir} do
    names = names()
    {:ok, clock_agent} = Agent.start_link(fn -> ~U[2026-08-04 00:00:00Z] end)
    clock = fn -> Agent.get(clock_agent, & &1) end

    config =
      Path.join(dir, "capture.db")
      |> capture_config(names)
      |> Map.merge(%{clock: clock, spool_max_age_days: 2})

    occurred_at = clock.() |> DateTime.to_iso8601()
    enqueued_at = "2026-08-04T00:00:00.000000Z"

    assert {:ok, supervisor} = CaptureSupervisor.start_link(config)

    accepted_ids =
      Enum.map(hook_payloads(occurred_at), fn {hook, payload} ->
        response = post_hook(hook, payload)
        assert response.status == 202

        assert %{"ok" => true, "status" => "accepted", "event_id" => event_id} =
                 Jason.decode!(response.resp_body)

        event_id
      end)

    assert %{
             pending_depth: 10,
             oldest_occurred_at: ^occurred_at,
             oldest_enqueued_at: ^enqueued_at,
             age_warning: false
           } = Spool.stats(names.spool)

    offline_uploader = Process.whereis(names.uploader)
    send(offline_uploader, :drain)
    assert %{connection_state: :disconnected} = CaptureUploader.status(offline_uploader)
    assert %{pending_depth: 10} = Spool.stats(names.spool)

    Agent.update(clock_agent, &DateTime.add(&1, 24, :hour))

    assert %{pending_depth: 10, oldest_enqueued_at: ^enqueued_at, age_warning: false} =
             Spool.stats(names.spool)

    assert 24 == DateTime.diff(clock.(), parse_datetime!(enqueued_at), :hour)

    Supervisor.stop(supervisor)

    assert {:ok, restarted} = CaptureSupervisor.start_link(config)

    assert %{
             pending_depth: 10,
             oldest_occurred_at: ^occurred_at,
             oldest_enqueued_at: ^enqueued_at,
             age_warning: false
           } = Spool.stats(names.spool)

    :persistent_term.put({ChannelProvider, :channel}, self())
    uploader = Process.whereis(names.uploader)
    send(uploader, :drain)

    assert_receive {:memory_events,
                    %{
                      "protocol" => "host_events.v1",
                      "host_id" => "trusted-host",
                      "events" => delivered
                    }},
                   1_000

    assert Enum.map(delivered, & &1["event_id"]) == accepted_ids
    assert Enum.map(delivered, & &1["sequence"]) == Enum.to_list(1..10)
    assert Enum.all?(delivered, &(&1["occurred_at"] == occurred_at))

    assert %{connection_state: :connected} = CaptureUploader.status(uploader)
    assert [] = Spool.next_batch(names.spool, 100, 524_288)
    assert %{pending_depth: 0} = Spool.stats(names.spool)
    refute_receive {:memory_events, _payload}, 50

    Supervisor.stop(restarted)
  end

  defp post_hook(hook, payload) do
    :post
    |> conn("/capture/v1/hooks/claude_code/#{hook}", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> then(&MemoryRouter.call(&1, MemoryRouter.init([])))
  end

  defp hook_payloads(occurred_at) do
    common = %{
      "session_id" => "claude-session-1",
      "cwd" => "/workspace/backplane",
      "occurred_at" => occurred_at
    }

    [
      {"session-start",
       Map.merge(common, %{"hook_event_name" => "SessionStart", "source" => "startup"})},
      {"user-prompt-submit",
       Map.merge(common, %{
         "hook_event_name" => "UserPromptSubmit",
         "prompt" => "implement durable capture"
       })},
      {"post-tool-use",
       Map.merge(common, %{
         "hook_event_name" => "PostToolUse",
         "tool_name" => "Read",
         "tool_use_id" => "tool-success",
         "tool_input" => %{"file_path" => "/workspace/backplane/mix.exs"},
         "tool_response" => %{"ok" => true}
       })},
      {"post-tool-use-failure",
       Map.merge(common, %{
         "hook_event_name" => "PostToolUseFailure",
         "tool_name" => "Bash",
         "tool_use_id" => "tool-failure",
         "tool_input" => %{"command" => "false"},
         "error" => "exit status 1"
       })},
      {"pre-compact",
       Map.merge(common, %{
         "hook_event_name" => "PreCompact",
         "trigger" => "auto",
         "custom_instructions" => "retain current task"
       })},
      {"subagent-start",
       Map.merge(common, %{
         "hook_event_name" => "SubagentStart",
         "agent_id" => "child-1",
         "agent_type" => "reviewer"
       })},
      {"subagent-stop",
       Map.merge(common, %{
         "hook_event_name" => "SubagentStop",
         "agent_id" => "child-1",
         "agent_type" => "reviewer",
         "last_assistant_message" => "review complete"
       })},
      {"stop",
       Map.merge(common, %{
         "hook_event_name" => "Stop",
         "last_assistant_message" => "implementation complete"
       })},
      {"session-end",
       Map.merge(common, %{"hook_event_name" => "SessionEnd", "reason" => "other"})},
      {"post-commit",
       Map.merge(common, %{
         "hook_event_name" => "PostToolUse",
         "tool_name" => "Bash",
         "tool_use_id" => "git-commit",
         "tool_input" => %{"command" => "git commit -m 'capture'"},
         "tool_response" => "[main abc123] capture"
       })}
    ]
  end

  defp capture_config(db_path, names) do
    %{
      enabled: true,
      db_path: db_path,
      host_id: "trusted-host",
      name: names.supervisor,
      spool_name: names.spool,
      uploader_name: names.uploader,
      channel_provider: ChannelProvider,
      channel_module: AcceptingChannel,
      upload_interval_ms: 0,
      batch_size: 100,
      batch_bytes: 524_288
    }
  end

  defp names do
    suffix = System.unique_integer([:positive])

    %{
      supervisor: :"capture_contract_supervisor_#{suffix}",
      spool: :"capture_contract_spool_#{suffix}",
      uploader: :"capture_contract_uploader_#{suffix}"
    }
  end

  defp parse_datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  defp restore_env(key, nil), do: Application.delete_env(:backplane_host_agent, key)
  defp restore_env(key, value), do: Application.put_env(:backplane_host_agent, key, value)
end
