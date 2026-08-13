defmodule Backplane.Memory.ActivityReplayServiceTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Audit, Service}
  alias Backplane.Memory.Events.Store
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Skills.Host

  defmodule ImportDispatcher do
    def call_local_tool(host_id, name, args, _timeout) do
      send(self(), {:import_dispatch, host_id, name, args})

      {:ok,
       %{
         batch_id: Ecto.UUID.generate(),
         status: "accepted",
         request_id: args["request_id"],
         ignored_private_path: "/never/return/this"
       }}
    end
  end

  @settings ~w(memory.pipeline.enabled memory.replay_enabled memory.replay_import_enabled memory.tools)

  setup do
    snapshot = Map.new(@settings, &{&1, :ets.lookup(:backplane_settings, &1)})
    dispatcher = Application.get_env(:backplane_memory, :replay_import_dispatcher)

    Enum.each(@settings -- ["memory.tools"], &:ets.insert(:backplane_settings, {&1, true}))
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    Application.put_env(:backplane_memory, :replay_import_dispatcher, ImportDispatcher)

    host =
      repo().insert!(
        Host.changeset(%Host{}, %{
          name: "activity-replay-#{System.unique_integer([:positive])}",
          memory_scope: "scope:activity-replay"
        })
      )

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)

      if dispatcher,
        do: Application.put_env(:backplane_memory, :replay_import_dispatcher, dispatcher),
        else: Application.delete_env(:backplane_memory, :replay_import_dispatcher)
    end)

    partition = %{
      host_id: host.id,
      client_id: "host:#{host.id}",
      scope: host.memory_scope,
      namespace: "private"
    }

    auth = %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      scopes: ["memory.read", "memory.replay", "memory.admin"],
      principal_metadata: %{"memory_partition_id" => partition.client_id}
    }

    %{partition: partition, auth: auth}
  end

  test "activity and replay tools return exact-partition durable data and audit reads", ctx do
    session = "public-replay-#{System.unique_integer([:positive])}"
    append!(ctx.partition, session, 1, "agent.session.started")
    append!(ctx.partition, session, 2, "conversation.agent_message")
    assert {:ok, _} = Rebuild.session(ctx.partition.host_id, session)

    assert {:ok, %{sessions: [%{session_id: ^session}]}} =
             Service.call("memory::replay_sessions", %{}, ctx.auth)

    assert {:ok, %{events: [_, _]}} =
             Service.call("memory::replay_load", %{"session_id" => session}, ctx.auth)

    assert {:ok, %{summary: summary}} = Service.call("memory::activity_summary", %{}, ctx.auth)
    assert summary.event_count >= 2

    for operation <- ~w(memory.replay.sessions memory.replay.load memory.activity.summary) do
      assert [_] = Audit.list(ctx.partition, operation: operation)
    end

    foreign = put_in(ctx.auth.principal_metadata["memory_partition_id"], "host:foreign")

    assert {:error, :unauthorized} =
             Service.call("memory::replay_load", %{"session_id" => session}, foreign)
  end

  test "direct replay calls enforce the published strict schemas", ctx do
    assert {:error, :invalid_arguments} =
             Service.call("memory::replay_sessions", %{"unknown" => true}, ctx.auth)

    assert {:error, :invalid_arguments} =
             Service.call("memory::replay_sessions", %{"limit" => "1"}, ctx.auth)

    assert {:error, :invalid_arguments} =
             Service.call(
               "memory::replay_load",
               %{"session_id" => "session", "limit" => 1, "unknown" => true},
               ctx.auth
             )
  end

  test "enabled import dispatch sends only an opaque host profile and bounded caps", ctx do
    assert {:ok, result} =
             Service.call(
               "memory::replay_import",
               %{"profile" => "claude_default", "request_id" => "batch-public"},
               ctx.auth
             )

    assert_receive {:import_dispatch, host_id, "memory.replay_import", payload}
    assert host_id == ctx.partition.host_id
    assert payload["profile"] == "claude_default"
    refute Map.has_key?(payload, "path")
    refute Map.has_key?(payload, "approved_roots")
    assert result["status"] == "accepted"
    assert result["request_id"] == "batch-public"
    refute inspect(result) =~ "/never/return/this"
    assert [_] = Audit.list(ctx.partition, operation: "memory.replay.import_dispatched")
  end

  test "activity summary is exposed as an authorized JSON resource", ctx do
    assert Enum.any?(Service.resources(ctx.auth), &(&1.uri == "memory://activity/summary"))
    assert {:ok, json} = Service.read_resource("memory://activity/summary", ctx.auth)
    assert %{"summary" => %{"event_count" => _}} = Jason.decode!(json)
  end

  defp append!(partition, session, sequence, event_type) do
    assert {:ok, {:inserted, _}} =
             Store.append_tagged(%{
               id: Ecto.UUID.generate(),
               stream_id: "capture:#{partition.host_id}:#{session}",
               host_id: partition.host_id,
               client_id: partition.client_id,
               scope: partition.scope,
               namespace: partition.namespace,
               session_id: session,
               sequence: sequence,
               source_sequence: sequence,
               event_type: event_type,
               occurred_at: DateTime.add(~U[2026-08-12 00:00:00.000000Z], sequence),
               idempotency_key: "#{session}:#{sequence}",
               payload: %{},
               payload_hash: "sha256:#{session}:#{sequence}",
               schema_version: 1
             })
  end
end
