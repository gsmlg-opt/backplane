defmodule Backplane.Memory.Graph.EdgeTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Graph.{Edge, Node}

  setup do
    %{partition: canonical_partition("graph-edge-#{System.unique_integer([:positive])}")}
  end

  defp insert_node(type, name, partition) do
    {:ok, node} =
      %Node{}
      |> Node.changeset(Map.merge(partition, %{type: type, name: name}))
      |> repo().insert()

    node
  end

  defp edge_attrs(partition, attrs), do: Map.merge(partition, attrs)

  describe "changeset/2 valid" do
    test "accepts a valid relation between two node IDs", %{partition: partition} do
      src = insert_node("Module", "Src", partition)
      tgt = insert_node("Module", "Tgt", partition)

      cs =
        Edge.changeset(
          %Edge{},
          edge_attrs(partition, %{
            source_id: src.id,
            target_id: tgt.id,
            relation: "depends_on"
          })
        )

      assert cs.valid?
    end

    test "accepts all valid relation types", %{partition: partition} do
      src = insert_node("File", "a.ex", partition)
      tgt = insert_node("File", "b.ex", partition)

      for rel <- ~w(uses imports calls depends_on tests documents caused_by supersedes relates_to) do
        cs =
          Edge.changeset(
            %Edge{},
            edge_attrs(partition, %{source_id: src.id, target_id: tgt.id, relation: rel})
          )

        assert cs.valid?, "expected valid for relation=#{rel}"
      end
    end

    test "accepts optional weight", %{partition: partition} do
      src = insert_node("Function", "foo/1", partition)
      tgt = insert_node("Function", "bar/2", partition)

      cs =
        Edge.changeset(
          %Edge{},
          edge_attrs(partition, %{
            source_id: src.id,
            target_id: tgt.id,
            relation: "calls",
            weight: 2.5
          })
        )

      assert cs.valid?
    end
  end

  describe "changeset/2 invalid" do
    test "rejects missing source_id", %{partition: partition} do
      tgt = insert_node("Module", "Tgt2", partition)
      cs = Edge.changeset(%Edge{}, edge_attrs(partition, %{target_id: tgt.id, relation: "uses"}))
      refute cs.valid?
      assert errors_on(cs)[:source_id]
    end

    test "rejects missing target_id", %{partition: partition} do
      src = insert_node("Module", "Src2", partition)
      cs = Edge.changeset(%Edge{}, edge_attrs(partition, %{source_id: src.id, relation: "uses"}))
      refute cs.valid?
      assert errors_on(cs)[:target_id]
    end

    test "rejects unknown relation", %{partition: partition} do
      src = insert_node("File", "x.ex", partition)
      tgt = insert_node("File", "y.ex", partition)

      cs =
        Edge.changeset(
          %Edge{},
          edge_attrs(partition, %{
            source_id: src.id,
            target_id: tgt.id,
            relation: "destroys"
          })
        )

      refute cs.valid?
      assert errors_on(cs)[:relation]
    end
  end
end
