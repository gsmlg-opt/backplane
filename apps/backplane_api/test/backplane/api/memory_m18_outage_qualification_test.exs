defmodule Backplane.Api.MemoryM18OutageQualificationTest do
  use Backplane.Api.ChannelCase, async: false

  import Ecto.Query

  alias Backplane.Api.HostAgentSocket
  alias Backplane.HostAgent.Memory.{CaptureUploader, EventEnvelope}
  alias Backplane.HostAgent.Memory.Spool.Turso, as: Spool
  alias Backplane.Memory.Events.Event
  alias Backplane.Memory.Projections.{ProjectedSession, State}
  alias Backplane.Memory.Workers.ProjectionRepairWorker
  alias Backplane.Repo
  alias Backplane.Skills.Hosts

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @event_count 30

  defmodule RealServerChannel do
    def push(_connected_pid, event, payload) do
      socket = Process.get({__MODULE__, :socket})
      Process.put({__MODULE__, :last_payload}, payload)
      ref = Phoenix.ChannelTest.push(socket, event, payload)

      receive do
        %Phoenix.Socket.Reply{ref: ^ref, status: :ok, payload: reply} -> {:ok, reply}
        %Phoenix.Socket.Reply{ref: ^ref, status: :error, payload: reply} -> {:error, reply}
      after
        5_000 -> {:error, :reply_timeout}
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    Application.delete_env(:backplane_api, :host_event_ingest_adapter)

    assert {:ok, host, _auth_token, token} =
             Hosts.create_agent_with_token(%{"name" => "m18-outage-host"})

    assert {:ok, socket} =
             connect(HostAgentSocket, %{"host_id" => host.id},
               connect_info: %{x_headers: [{"x-backplane-host-token", token}]}
             )

    assert {:ok, _reply, socket} = subscribe_and_join(socket, "host_agent:#{host.id}", %{})

    spool =
      start_supervised!(
        {Spool,
         database: Path.join(tmp_dir, "m18-outage.db"),
         name: nil,
         id: {:m18_outage_spool, System.unique_integer([:positive])}}
      )

    on_exit(fn ->
      Application.delete_env(:backplane_api, :host_event_ingest_adapter)
      Process.delete({RealServerChannel, :socket})
      Process.delete({RealServerChannel, :last_payload})
    end)

    %{host: host, socket: socket, spool: spool}
  end

  test "a 24-hour host outage drains every local acceptance through real ingest and projections",
       %{host: host, socket: socket, spool: spool} do
    events = Enum.map(1..@event_count, &outage_event(host, &1))

    for event <- events do
      assert {:ok, _envelope} = Spool.append(spool, event)
    end

    assert %{pending_depth: @event_count, captured_count: @event_count} = Spool.stats(spool)

    assert {:ok, %{"status" => "disconnected", "drained" => 0}} =
             CaptureUploader.drain_once(spool: spool, channel: nil, host_id: host.id)

    assert %{pending_depth: @event_count} = Spool.stats(spool)

    Process.put({RealServerChannel, :socket}, socket)

    assert {:ok,
            %{
              "status" => "delivered",
              "selected" => @event_count,
              "acknowledged" => @event_count,
              "dead_lettered" => 0,
              "retryable" => 0,
              "unacknowledged" => 0
            }} =
             CaptureUploader.drain_once(
               spool: spool,
               channel: self(),
               channel_module: RealServerChannel,
               host_id: host.id
             )

    assert %{pending_depth: 0} = Spool.stats(spool)

    persisted =
      Repo.all(
        from(event in Event, where: event.host_id == ^host.id, order_by: event.source_sequence)
      )

    assert length(persisted) == @event_count

    for event <- persisted do
      assert :ok = ProjectionRepairWorker.perform(%Oban.Job{args: %{"event_id" => event.id}})
    end

    projected_sessions =
      Repo.all(from(session in ProjectedSession, where: session.host_id == ^host.id))

    assert length(projected_sessions) == @event_count
    subject_ids = Enum.map(projected_sessions, & &1.subject_id)

    assert Repo.aggregate(
             from(state in State,
               where:
                 state.subject_type == "captured_session" and state.status == "complete" and
                   state.projector in ["observations", "session", "activity", "replay"] and
                   state.subject_id in ^subject_ids
             ),
             :count
           ) == @event_count * 4

    retry_payload =
      RealServerChannel
      |> then(&Process.get({&1, :last_payload}))
      |> Map.put("batch_id", "m18-outage-duplicate-retry")

    retry_ref = push(socket, "memory_events", retry_payload)

    assert_reply(retry_ref, :ok, %{"results" => duplicate_results}, 5_000)
    assert length(duplicate_results) == @event_count
    assert Enum.all?(duplicate_results, &(&1["status"] == "duplicate"))

    assert Repo.aggregate(from(event in Event, where: event.host_id == ^host.id), :count) ==
             @event_count
  end

  defp outage_event(host, sequence) do
    payload = %{"message" => "accepted during outage #{sequence}"}
    occurred_at = DateTime.add(DateTime.utc_now(), -24 * 60 * 60 + sequence, :second)

    %{
      event_id: Ecto.UUID.generate(),
      schema_version: 1,
      host_id: host.id,
      agent_id: "m18-outage-agent",
      client_id: "codex-cli",
      integration: "codex",
      project: "/qualification/memory-v2",
      scope: host.memory_scope,
      session_id: "m18-outage-session-#{sequence}",
      parent_session_id: nil,
      sequence: 1,
      event_type: "agent.prompt.submitted",
      occurred_at: DateTime.to_iso8601(occurred_at),
      captured_at: DateTime.to_iso8601(occurred_at),
      idempotency_key: "m18-outage:#{sequence}",
      payload_hash: EventEnvelope.payload_hash(payload),
      privacy: %{"filtered" => true, "filter_version" => "1"},
      trace: %{"correlation_id" => "m18-outage-#{sequence}"},
      payload: payload
    }
  end
end
