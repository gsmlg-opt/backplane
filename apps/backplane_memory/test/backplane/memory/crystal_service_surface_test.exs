defmodule Backplane.Memory.CrystalServiceSurfaceTest do
  use Backplane.Memory.DataCase, async: false

  import Backplane.Memory.IngestFixtures

  alias Backplane.Memory.{Audit, Ingest, Service}
  alias Backplane.Memory.Coordination.Action
  alias Backplane.Memory.Projections.Rebuild
  alias Backplane.Memory.Workers.CrystalWorker
  alias Backplane.Skills.Host

  setup do
    previous = :ets.lookup(:backplane_settings, "memory.tools")
    previous_llm = Application.get_env(:backplane_memory, :llm_client)
    Application.put_env(:backplane_memory, :llm_client, __MODULE__)

    on_exit(fn ->
      :ets.delete(:backplane_settings, "memory.tools")
      if previous != [], do: :ets.insert(:backplane_settings, previous)

      if previous_llm,
        do: Application.put_env(:backplane_memory, :llm_client, previous_llm),
        else: Application.delete_env(:backplane_memory, :llm_client)
    end)

    :ok
  end

  test "crystal reads are core while crystallization is extended governance" do
    :ets.insert(:backplane_settings, {"memory.tools", "core"})
    core = Map.new(Service.tools(), &{&1.name, &1})

    assert Map.has_key?(core, "memory::crystal_get")
    assert Map.has_key?(core, "memory::crystal_list")
    assert Map.has_key?(core, "memory::crystal_search")
    refute Map.has_key?(core, "memory::crystallize")

    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    all = Map.new(Service.tools(), &{&1.name, &1})
    assert all["memory::crystallize"].permission == "memory.admin"
    assert all["memory::crystal_get"].permission == "memory.read"
  end

  test "crystal contracts are strict and bounded" do
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    tools = Map.new(Service.tools(), &{&1.name, &1.input_schema})

    assert tools["memory::crystal_get"]["additionalProperties"] == false

    assert tools["memory::crystal_list"]["properties"]["limit"] == %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => 100,
             "default" => 20
           }

    assert tools["memory::crystal_search"]["required"] == ["query"]
    assert tools["memory::crystal_search"]["properties"]["query"]["maxLength"] == 4096
    assert tools["memory::crystal_list"]["properties"]["after"]["maxLength"] == 4096

    assert tools["memory::crystallize"]["properties"]["source_kind"]["enum"] ==
             ["session", "action_chain"]
  end

  test "crystal resource remains fail closed without auth" do
    assert {:error, :unauthorized} = Service.read_resource("memory://crystals/latest")
  end

  test "action-chain crystallize is idempotent, partitioned, searchable, and content-free audited" do
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    {host, auth, partition} = authorized_partition("crystal-surface")

    assert {:ok, action} =
             Action.create(
               %{
                 "title" => "Ship crystal surfaces",
                 "description" => "Sensitive implementation narrative",
                 "status" => "done",
                 "created_by" => "surface-agent",
                 "project" => "backplane"
               },
               [],
               partition
             )

    args = %{
      "source_kind" => "action_chain",
      "root_action_id" => action.id,
      "request_id" => "crystal-request",
      "correlation_id" => "crystal-correlation"
    }

    assert {:ok, first} = Service.call("memory::crystallize", args, auth)
    assert {:ok, second} = Service.call("memory::crystallize", args, auth)
    assert first.crystal_id == second.crystal_id

    assert {:ok, detail} =
             Service.call("memory::crystal_get", %{"crystal_id" => first.crystal_id}, auth)

    assert detail.source_action_ids == [action.id]
    assert detail.source_kind == "action_chain"
    assert detail.status == "complete"

    assert {:ok, %{results: [listed], next_cursor: nil}} =
             Service.call("memory::crystal_list", %{"limit" => 1}, auth)

    assert listed.crystal_id == first.crystal_id

    assert {:ok, %{results: [%{crystal_id: crystal_id}]}} =
             Service.call("memory::crystal_search", %{"query" => "Ship surfaces"}, auth)

    assert crystal_id == first.crystal_id

    {_foreign_host, foreign_auth, _foreign_partition} = authorized_partition("crystal-foreign")

    assert {:error, :not_found} =
             Service.call(
               "memory::crystal_get",
               %{"crystal_id" => first.crystal_id},
               foreign_auth
             )

    assert {:ok, %{results: []}} =
             Service.call("memory::crystal_search", %{"query" => "Ship surfaces"}, foreign_auth)

    assert {:ok, resource_json} = Service.read_resource("memory://crystals/latest", auth)
    assert %{"results" => [%{"crystal_id" => ^crystal_id}]} = Jason.decode!(resource_json)

    assert [latest, earlier] = Audit.list(partition, operation: "crystal.crystallize")

    for audit <- [latest, earlier] do
      assert audit.actor == "surface-actor"
      assert audit.metadata["request_id"] == "crystal-request"
      assert audit.metadata["correlation_id"] == "crystal-correlation"
      assert audit.target_ids["crystal_id"] == first.crystal_id
      assert audit.metadata["result"] == "complete"
      refute inspect(audit) =~ "Sensitive implementation narrative"
    end

    assert host.id == partition.host_id
  end

  test "strict handlers reject unknown fields and unbounded pagination" do
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    {_host, auth, _partition} = authorized_partition("crystal-strict")

    assert {:error, :invalid_arguments} =
             Service.call("memory::crystal_list", %{"limit" => 101}, auth)

    assert {:error, :invalid_arguments} =
             Service.call("memory::crystal_search", %{"query" => "x", "extra" => true}, auth)

    assert {:error, :invalid_arguments} =
             Service.call(
               "memory::crystal_search",
               %{"query" => String.duplicate("x", 4097)},
               auth
             )

    assert {:error, :invalid_arguments} =
             Service.call("memory::crystal_list", %{"after" => String.duplicate("x", 4097)}, auth)

    assert {:error, :invalid_arguments} =
             Service.call(
               "memory::crystallize",
               %{
                 "source_kind" => "action_chain",
                 "root_action_id" => Ecto.UUID.generate(),
                 "actor" => "spoof"
               },
               auth
             )
  end

  test "a stale session enqueue returns a stable skipped response without a job id" do
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    {_host, auth, partition} = authorized_partition("crystal-stale-surface")
    session_id = "surface-session-#{System.unique_integer([:positive])}"

    for {sequence, type} <- [
          {1, "agent.session.started"},
          {2, "agent.tool.completed"},
          {3, "agent.session.ended"}
        ] do
      ingest_event!(partition, session_id, sequence, type)
    end

    assert {:ok, projection} = Rebuild.session(partition.host_id, session_id)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _job} =
               CrystalWorker.enqueue(partition.host_id, session_id, projection.input_revision)
    end)

    ingest_event!(partition, session_id, 4, "agent.tool.completed")

    assert {:ok,
            %{
              status: "skipped",
              source_kind: "session",
              source_session_id: ^session_id,
              input_revision: input_revision,
              job_id: nil
            }} =
             Service.call(
               "memory::crystallize",
               %{"source_kind" => "session", "session_id" => session_id},
               auth
             )

    assert input_revision == projection.input_revision

    assert [%{metadata: %{"result" => "skipped"}}] =
             Audit.list(partition, operation: "crystal.crystallize")
  end

  test "a new session enqueue audits the stable enqueued classification" do
    :ets.insert(:backplane_settings, {"memory.tools", "all"})
    {_host, auth, partition} = authorized_partition("crystal-enqueued-surface")
    session_id = "surface-enqueued-#{System.unique_integer([:positive])}"

    for {sequence, type} <- [
          {1, "agent.session.started"},
          {2, "agent.tool.completed"},
          {3, "agent.session.ended"}
        ] do
      ingest_event!(partition, session_id, sequence, type)
    end

    assert {:ok, _projection} = Rebuild.session(partition.host_id, session_id)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{status: "enqueued", job_id: job_id}} =
               Service.call(
                 "memory::crystallize",
                 %{"source_kind" => "session", "session_id" => session_id},
                 auth
               )

      assert is_integer(job_id)
    end)

    assert [%{metadata: %{"result" => "enqueued"}}] =
             Audit.list(partition, operation: "crystal.crystallize")
  end

  defp authorized_partition(prefix) do
    host =
      repo().insert!(
        Host.changeset(%Host{}, %{
          name: "#{prefix}-#{System.unique_integer([:positive])}",
          memory_scope: "scope:#{prefix}"
        })
      )

    client_id = "host:#{host.id}"

    auth = %{
      kind: :client_token,
      client_id: Ecto.UUID.generate(),
      subject: "surface-actor",
      scopes: ["memory.read", "memory.admin"],
      principal_metadata: %{"memory_partition_id" => client_id}
    }

    partition = %{
      host_id: host.id,
      client_id: client_id,
      scope: host.memory_scope,
      namespace: "private"
    }

    {host, auth, partition}
  end

  defp ingest_event!(partition, session_id, sequence, event_type) do
    event =
      valid_event(%{
        "event_id" => Ecto.UUID.generate(),
        "host_id" => partition.host_id,
        "client_id" => partition.client_id,
        "scope" => partition.scope,
        "session_id" => session_id,
        "sequence" => sequence,
        "event_type" => event_type,
        "occurred_at" => "2026-08-12T00:0#{sequence}:00.000Z",
        "idempotency_key" => "#{session_id}:#{sequence}",
        "payload" => %{"source" => %{"message" => "event #{sequence}"}}
      })

    assert {:ok, %{"results" => [%{"status" => "accepted"}]}} =
             Ingest.ingest_batch(
               ingest_auth_context(partition.host_id, %{
                 auth_token_id: "surface-token",
                 partition: %{scope: partition.scope}
               }),
               %{
                 "batch_id" => Ecto.UUID.generate(),
                 "host_id" => partition.host_id,
                 "events" => [event]
               }
             )
  end
end
