defmodule Backplane.Docs.ReindexStateTest do
  use Backplane.DataCase, async: true

  alias Backplane.Docs.ReindexState

  @valid_attrs %{
    project_id: "test-project",
    status: "pending",
    commit_sha: "abc123def456",
    started_at: ~U[2026-01-01 00:00:00.000000Z]
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
      cs = ReindexState.changeset(%ReindexState{}, @valid_attrs)
      assert cs.valid?
    end

    test "requires project_id" do
      cs = ReindexState.changeset(%ReindexState{}, Map.delete(@valid_attrs, :project_id))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :project_id)
    end

    test "requires status" do
      cs = ReindexState.changeset(%ReindexState{}, %{@valid_attrs | status: nil})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :status)
    end

    test "validates status inclusion" do
      cs = ReindexState.changeset(%ReindexState{}, %{@valid_attrs | status: "invalid"})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :status)
    end

    test "accepts all valid status values" do
      for status <- ~w(pending running completed failed) do
        cs = ReindexState.changeset(%ReindexState{}, %{@valid_attrs | status: status})
        assert cs.valid?, "expected status #{status} to be valid"
      end
    end

    test "accepts optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          completed_at: ~U[2026-01-01 00:01:00.000000Z],
          chunk_count: 42
        })

      cs = ReindexState.changeset(%ReindexState{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :chunk_count) == 42
    end

    test "inserts into database with valid attrs" do
      {:ok, state} =
        %ReindexState{}
        |> ReindexState.changeset(@valid_attrs)
        |> Repo.insert()

      assert state.project_id == "test-project"
      assert state.status == "pending"
    end
  end
end
