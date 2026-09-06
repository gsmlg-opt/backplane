defmodule Backplane.Memory.Graph.NodeTest do
  use Backplane.Memory.DataCase, async: true

  alias Backplane.Memory.Graph.Node

  setup do
    %{partition: canonical_partition("graph-node-#{System.unique_integer([:positive])}")}
  end

  defp node_attrs(partition, attrs), do: Map.merge(partition, attrs)

  describe "changeset/2 valid" do
    test "accepts a valid type and name", %{partition: partition} do
      cs = Node.changeset(%Node{}, node_attrs(partition, %{type: "File", name: "lib/foo.ex"}))
      assert cs.valid?
    end

    test "accepts all valid types", %{partition: partition} do
      for type <- ~w(File Function Module Library Concept Decision Bug Pattern Person) do
        cs = Node.changeset(%Node{}, node_attrs(partition, %{type: type, name: "example"}))
        assert cs.valid?, "expected valid for type=#{type}"
      end
    end

    test "accepts optional properties and source_observation_ids", %{partition: partition} do
      id = Ecto.UUID.generate()

      cs =
        Node.changeset(
          %Node{},
          node_attrs(partition, %{
            type: "Concept",
            name: "caching",
            properties: %{"key" => "val"},
            source_observation_ids: [id]
          })
        )

      assert cs.valid?
    end
  end

  describe "changeset/2 invalid" do
    test "rejects missing name" do
      cs = Node.changeset(%Node{}, %{type: "File"})
      refute cs.valid?
      assert errors_on(cs)[:name]
    end

    test "rejects missing type" do
      cs = Node.changeset(%Node{}, %{name: "foo"})
      refute cs.valid?
      assert errors_on(cs)[:type]
    end

    test "rejects unknown type" do
      cs = Node.changeset(%Node{}, %{type: "Unicorn", name: "foo"})
      refute cs.valid?
      assert errors_on(cs)[:type]
    end
  end

  describe "insert" do
    test "inserts a valid node into the database", %{partition: partition} do
      {:ok, node} =
        %Node{}
        |> Node.changeset(node_attrs(partition, %{type: "Module", name: "MyApp.Repo"}))
        |> repo().insert()

      assert node.id != nil
      assert node.name == "MyApp.Repo"
    end
  end
end
