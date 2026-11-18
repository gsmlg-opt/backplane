defmodule Backplane.HostAgent.Memory.SynapsisCaptureTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Backplane.HostAgent.Memory.{CaptureSupervisor, CaptureUploader}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.HostAgent.MemoryRouter
  alias Backplane.Memory.Ingest.EventValidator

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
           Enum.map(payload["events"], &%{"event_id" => &1["event_id"], "status" => "accepted"})
       }}
    end
  end

  setup do
    previous_runtime = Application.get_env(:backplane_host_agent, :capture_runtime)
    :persistent_term.put({ChannelProvider, :channel}, nil)

    on_exit(fn ->
      :persistent_term.erase({ChannelProvider, :channel})

      if previous_runtime,
        do: Application.put_env(:backplane_host_agent, :capture_runtime, previous_runtime),
        else: Application.delete_env(:backplane_host_agent, :capture_runtime)
    end)
  end

  test "four HTTP hooks survive restart and upload once with their provenance", %{tmp_dir: dir} do
    clock = start_supervised!({Agent, fn -> ~U[2026-11-19 08:00:00Z] end})
    suffix = System.unique_integer([:positive])
    spool = :"synapsis_spool_#{suffix}"
    uploader = :"synapsis_uploader_#{suffix}"

    config = %{
      enabled: true,
      db_path: Path.join(dir, "capture.db"),
      host_id: "trusted-host",
      name: :"synapsis_capture_#{suffix}",
      spool_name: spool,
      uploader_name: uploader,
      channel_provider: ChannelProvider,
      channel_module: AcceptingChannel,
      upload_interval_ms: 0,
      clock: fn -> Agent.get(clock, & &1) end
    }

    {:ok, supervisor} = CaptureSupervisor.start_link(config)
    sources = sources()

    for {hook, source} <- sources do
      assert %{"status" => "accepted", "event_id" => event_id} = post_hook(hook, source)
      assert event_id == source["event_id"]
      assert %{"status" => "duplicate", "event_id" => ^event_id} = post_hook(hook, source)
    end

    assert %{pending_depth: 4} = Spool.stats(spool)
    Supervisor.stop(supervisor)
    {:ok, restarted} = CaptureSupervisor.start_link(config)

    :persistent_term.put({ChannelProvider, :channel}, self())
    send(Process.whereis(uploader), :drain)

    assert_receive {:memory_events, %{"protocol" => "host_events.v1", "events" => events}}, 1_000
    assert %{connection_state: :connected} = CaptureUploader.status(Process.whereis(uploader))
    assert %{pending_depth: 0} = Spool.stats(spool)
    assert Enum.map(events, & &1["sequence"]) == [1, 2, 3, 4]

    for {event, {hook, source}} <- Enum.zip(events, sources) do
      assert event["integration"] == "synapsis"
      assert event["host_id"] == "trusted-host"
      assert event["agent_id"] == "Rikka"
      assert event["event_id"] == source["event_id"]
      assert event["session_id"] == source["session_id"]
      assert event["project"] == source["cwd"]
      assert event["payload"]["hook"] == hook
      assert event["payload"]["source"] == source
      assert {:ok, _validated} = EventValidator.validate(event)
    end

    Agent.update(clock, &DateTime.add(&1, 61, :second))
    send(Process.whereis(spool), :compact_acknowledged)
    assert %{pending_depth: 0} = Spool.stats(spool)

    Supervisor.stop(restarted)
    {:ok, after_delivery} = CaptureSupervisor.start_link(config)

    for {hook, source} <- sources do
      assert %{"status" => "duplicate", "event_id" => event_id} = post_hook(hook, source)
      assert event_id == source["event_id"]
    end

    {prompt_hook, prompt_source} = Enum.at(sources, 1)

    assert %{"error" => "capture identity collision"} =
             post_hook(
               prompt_hook,
               Map.put(prompt_source, "event_id", "3c330d38-f351-4aa6-9c77-3914f3e93c20"),
               400
             )

    assert %{pending_depth: 0} = Spool.stats(spool)
    send(Process.whereis(uploader), :drain)
    assert %{connection_state: :connected} = CaptureUploader.status(Process.whereis(uploader))
    refute_receive {:memory_events, _}, 50
    Supervisor.stop(after_delivery)
  end

  defp post_hook(hook, source, expected_status \\ 202) do
    response =
      :post
      |> conn("/capture/v1/hooks/synapsis/#{hook}", Jason.encode!(source))
      |> put_req_header("content-type", "application/json")
      |> then(&MemoryRouter.call(&1, MemoryRouter.init([])))

    assert response.status == expected_status
    Jason.decode!(response.resp_body)
  end

  defp sources do
    common = %{
      "schema_version" => "1.0",
      "session_id" => "a214a528-03cf-4338-b184-851bd5f94cd2",
      "cwd" => "/workspace/backplane",
      "timestamp" => "2026-11-19T08:00:00Z",
      "agent_id" => "Rikka"
    }

    [
      {"session-start", %{}},
      {"user-prompt-submit",
       %{"message_id" => "accepted-input", "content" => "capture this turn"}},
      {"post-tool-use",
       %{
         "tool_call_id" => "native-call",
         "tool_name" => "read_file",
         "is_error" => false,
         "result" => %{"content" => "public result"}
       }},
      {"session-end", %{"reason" => "normal"}}
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {{hook, payload}, index} ->
      event_id = "2c330d38-f351-4aa6-9c77-3914f3e93c2#{index}"
      {hook, Map.merge(common, %{"event_id" => event_id, "payload" => payload})}
    end)
  end
end
