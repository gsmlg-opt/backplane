defmodule Backplane.Memory.PartitionIdentityTest do
  use ExUnit.Case, async: true

  alias Backplane.Memory.PartitionIdentity

  @space_id "8eb90c8f-6d77-46e5-a7c8-5223186ae2bc"

  @direct_root_schemas [
    Backplane.Memory.Events.Event,
    Backplane.Memory.Events.Stream,
    Backplane.Memory.Memories.Memory,
    Backplane.Memory.Observations.Observation,
    Backplane.Memory.Observations.Session,
    Backplane.Memory.Projections.ProjectedObservation,
    Backplane.Memory.Projections.ProjectedSession,
    Backplane.Memory.Summaries.Summary,
    Backplane.Memory.Crystals.Crystal,
    Backplane.Memory.Profiles.Profile,
    Backplane.Memory.Graph.Node,
    Backplane.Memory.Graph.Edge,
    Backplane.Memory.Projections.ActivityDaily,
    Backplane.Memory.Projections.ActivityContribution,
    Backplane.Memory.Replay.Event,
    Backplane.Memory.Recall.Run,
    Backplane.Memory.Coordination.Action,
    Backplane.Memory.Coordination.Lease,
    Backplane.Memory.Coordination.Signal,
    Backplane.Memory.Slots.Slot,
    Backplane.Memory.Imports.ImportBatch,
    Backplane.Memory.Projections.State,
    Backplane.Memory.Projections.Snapshot
  ]

  test "accepts and normalizes one complete canonical partition" do
    assert {:ok,
            %{
              memory_space_id: @space_id,
              scope: "project:alpha",
              namespace: "team:backend",
              host_id: "host-a",
              source_client_id: "client-a",
              client_id: "client-a"
            }} =
             PartitionIdentity.validate(%{
               "memory_space_id" => @space_id,
               "scope" => " project:alpha ",
               "namespace" => " team:backend ",
               "host_id" => "host-a",
               "source_client_id" => "client-a",
               "client_id" => "client-a"
             })
  end

  test "rejects missing, blank, and malformed canonical identity" do
    for partition <- [
          %{scope: "scope", namespace: "private"},
          %{memory_space_id: nil, scope: "scope", namespace: "private"},
          %{memory_space_id: " ", scope: "scope", namespace: "private"},
          %{memory_space_id: "not-a-uuid", scope: "scope", namespace: "private"},
          %{memory_space_id: @space_id, scope: " ", namespace: "private"},
          %{memory_space_id: @space_id, scope: "scope", namespace: " "}
        ] do
      assert {:error, :incomplete_partition} = PartitionIdentity.validate(partition)
    end
  end

  test "rejects redundant atom/string identities that disagree" do
    assert {:error, :partition_mismatch} =
             PartitionIdentity.validate(%{
               "memory_space_id" => "97f65291-8b60-4f90-9fad-5fb0fc6e5ca2",
               memory_space_id: @space_id,
               scope: "scope",
               namespace: "private"
             })
  end

  test "validates an untrusted partition against the authenticated partition" do
    expected = %{memory_space_id: @space_id, scope: "scope", namespace: "private"}

    assert {:ok, validated} = PartitionIdentity.validate(expected, expected)
    assert validated.memory_space_id == @space_id

    assert {:error, :partition_mismatch} =
             PartitionIdentity.validate(
               %{expected | namespace: "shared"},
               expected
             )
  end

  test "every direct memory root exposes canonical ownership and explicit provenance" do
    Enum.each(@direct_root_schemas, fn schema ->
      fields = schema.__schema__(:fields)

      for field <- [:memory_space_id, :host_id, :source_client_id, :scope, :namespace] do
        assert field in fields, "#{inspect(schema)} is missing #{field}"
      end
    end)
  end
end
