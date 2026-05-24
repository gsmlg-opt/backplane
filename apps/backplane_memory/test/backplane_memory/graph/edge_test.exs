defmodule BackplaneMemory.Graph.EdgeTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Graph.{Edge, Node}

  defp insert_node(type, name) do
    {:ok, node} =
      %Node{}
      |> Node.changeset(%{type: type, name: name})
      |> repo().insert()

    node
  end

  describe "changeset/2 valid" do
    test "accepts a valid relation between two node IDs" do
      src = insert_node("Module", "Src")
      tgt = insert_node("Module", "Tgt")

      cs =
        Edge.changeset(%Edge{}, %{
          source_id: src.id,
          target_id: tgt.id,
          relation: "depends_on"
        })

      assert cs.valid?
    end

    test "accepts all valid relation types" do
      src = insert_node("File", "a.ex")
      tgt = insert_node("File", "b.ex")

      for rel <- ~w(uses imports calls depends_on tests documents caused_by supersedes relates_to) do
        cs = Edge.changeset(%Edge{}, %{source_id: src.id, target_id: tgt.id, relation: rel})
        assert cs.valid?, "expected valid for relation=#{rel}"
      end
    end

    test "accepts optional weight" do
      src = insert_node("Function", "foo/1")
      tgt = insert_node("Function", "bar/2")

      cs =
        Edge.changeset(%Edge{}, %{
          source_id: src.id,
          target_id: tgt.id,
          relation: "calls",
          weight: 2.5
        })

      assert cs.valid?
    end
  end

  describe "changeset/2 invalid" do
    test "rejects missing source_id" do
      tgt = insert_node("Module", "Tgt2")
      cs = Edge.changeset(%Edge{}, %{target_id: tgt.id, relation: "uses"})
      refute cs.valid?
      assert errors_on(cs)[:source_id]
    end

    test "rejects missing target_id" do
      src = insert_node("Module", "Src2")
      cs = Edge.changeset(%Edge{}, %{source_id: src.id, relation: "uses"})
      refute cs.valid?
      assert errors_on(cs)[:target_id]
    end

    test "rejects unknown relation" do
      src = insert_node("File", "x.ex")
      tgt = insert_node("File", "y.ex")

      cs =
        Edge.changeset(%Edge{}, %{
          source_id: src.id,
          target_id: tgt.id,
          relation: "destroys"
        })

      refute cs.valid?
      assert errors_on(cs)[:relation]
    end
  end
end
