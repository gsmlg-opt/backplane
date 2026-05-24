defmodule BackplaneMemory.Graph.NodeTest do
  use BackplaneMemory.DataCase, async: true

  alias BackplaneMemory.Graph.Node

  describe "changeset/2 valid" do
    test "accepts a valid type and name" do
      cs = Node.changeset(%Node{}, %{type: "File", name: "lib/foo.ex"})
      assert cs.valid?
    end

    test "accepts all valid types" do
      for type <- ~w(File Function Module Library Concept Decision Bug Pattern Person) do
        cs = Node.changeset(%Node{}, %{type: type, name: "example"})
        assert cs.valid?, "expected valid for type=#{type}"
      end
    end

    test "accepts optional properties and source_observation_ids" do
      id = Ecto.UUID.generate()

      cs =
        Node.changeset(%Node{}, %{
          type: "Concept",
          name: "caching",
          properties: %{"key" => "val"},
          source_observation_ids: [id]
        })

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
    test "inserts a valid node into the database" do
      {:ok, node} =
        %Node{}
        |> Node.changeset(%{type: "Module", name: "MyApp.Repo"})
        |> repo().insert()

      assert node.id != nil
      assert node.name == "MyApp.Repo"
    end
  end
end
