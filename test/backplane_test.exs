defmodule BackplaneTest do
  use Backplane.DataCase, async: true

  describe "public API" do
    test "list_tools returns a list" do
      assert is_list(Backplane.list_tools())
    end

    test "tool_count returns a non-negative integer" do
      assert is_integer(Backplane.tool_count())
      assert Backplane.tool_count() >= 0
    end

    test "search_skills returns a list" do
      assert is_list(Backplane.search_skills("test"))
    end

    test "skill_count returns a non-negative integer" do
      assert is_integer(Backplane.skill_count())
      assert Backplane.skill_count() >= 0
    end

    test "version returns a string" do
      assert is_binary(Backplane.version())
      assert Backplane.version() =~ ~r/^\d+\.\d+\.\d+$/
    end

    test "discover delegates to Hub.Discover" do
      assert {:ok, results} = Backplane.discover("test")
      assert is_map(results)
    end

    test "search_docs returns results for valid project" do
      # Insert a project + chunk so search has something to find
      Backplane.Repo.insert(
        %Backplane.Docs.Project{id: "api-test-proj", repo: "test/api", ref: "main"},
        on_conflict: :nothing
      )

      hash = "apitest#{System.unique_integer([:positive])}"

      Backplane.Repo.insert(%Backplane.Docs.DocChunk{
        project_id: "api-test-proj",
        source_path: "lib/api.ex",
        content: "Public API test content for searching",
        chunk_type: "module_doc",
        content_hash: hash
      })

      results = Backplane.search_docs("api-test-proj", "test")
      assert [_ | _] = results
    end
  end
end
