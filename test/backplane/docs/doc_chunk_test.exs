defmodule Backplane.Docs.DocChunkTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.DocChunk

  @valid_attrs %{
    project_id: "test-project",
    source_path: "lib/foo.ex",
    chunk_type: "module_doc",
    content: "Some documentation content",
    content_hash: "abc123"
  }

  setup do
    Repo.insert!(
      %Backplane.Docs.Project{id: "test-project", repo: "https://github.com/t/r.git"},
      on_conflict: :nothing
    )

    :ok
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = DocChunk.changeset(%DocChunk{}, @valid_attrs)
      assert cs.valid?
    end

    test "requires project_id" do
      cs = DocChunk.changeset(%DocChunk{}, Map.delete(@valid_attrs, :project_id))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :project_id)
    end

    test "requires source_path" do
      cs = DocChunk.changeset(%DocChunk{}, Map.delete(@valid_attrs, :source_path))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :source_path)
    end

    test "requires chunk_type" do
      cs = DocChunk.changeset(%DocChunk{}, Map.delete(@valid_attrs, :chunk_type))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :chunk_type)
    end

    test "requires content" do
      cs = DocChunk.changeset(%DocChunk{}, Map.delete(@valid_attrs, :content))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :content)
    end

    test "requires content_hash" do
      cs = DocChunk.changeset(%DocChunk{}, Map.delete(@valid_attrs, :content_hash))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :content_hash)
    end

    test "accepts optional fields" do
      attrs = Map.merge(@valid_attrs, %{module: "Foo", function: "bar/2", tokens: 42})
      cs = DocChunk.changeset(%DocChunk{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :module) == "Foo"
      assert Ecto.Changeset.get_change(cs, :tokens) == 42
    end

    test "inserts into database with valid attrs" do
      {:ok, chunk} =
        %DocChunk{}
        |> DocChunk.changeset(@valid_attrs)
        |> Repo.insert()

      assert chunk.id
      assert chunk.project_id == "test-project"
    end
  end
end
