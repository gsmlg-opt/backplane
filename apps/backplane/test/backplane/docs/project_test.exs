defmodule Backplane.Docs.ProjectTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.Project

  @valid_attrs %{id: "test-proj", repo: "https://github.com/test/repo.git"}

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Project.changeset(%Project{}, @valid_attrs)
      assert cs.valid?
    end

    test "requires id" do
      cs = Project.changeset(%Project{}, Map.delete(@valid_attrs, :id))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :id)
    end

    test "requires repo" do
      cs = Project.changeset(%Project{}, Map.delete(@valid_attrs, :repo))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :repo)
    end

    test "accepts optional fields" do
      attrs = Map.merge(@valid_attrs, %{ref: "develop", description: "A test project"})
      cs = Project.changeset(%Project{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :ref) == "develop"
      assert Ecto.Changeset.get_change(cs, :description) == "A test project"
    end

    test "ref defaults to main in schema" do
      {:ok, project} =
        %Project{}
        |> Project.changeset(@valid_attrs)
        |> Repo.insert()

      assert project.ref == "main"
    end

    test "accepts last_indexed_at and index_hash" do
      now = DateTime.utc_now()

      attrs =
        Map.merge(@valid_attrs, %{last_indexed_at: now, index_hash: "sha256hash"})

      cs = Project.changeset(%Project{}, attrs)
      assert cs.valid?
    end
  end
end
